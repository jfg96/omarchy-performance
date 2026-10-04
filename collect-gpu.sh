#!/usr/bin/env bash

set -u

# The root override allows fixture tests without touching the host's sysfs.
drm_root=${PERFORMANCE_DRM_ROOT:-/sys/class/drm}
pci_root=${PERFORMANCE_PCI_ROOT:-/sys/bus/pci/devices}
pci_ids=${PERFORMANCE_PCI_IDS:-/usr/share/hwdata/pci.ids}
smi=${PERFORMANCE_NVIDIA_SMI:-nvidia-smi}

printf 'GPU_SCAN\n'

clean_field() {
  local value=${1//$'\t'/ }
  value=${value//$'\n'/ }
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_number() {
  local value
  [[ -r "$1" ]] || { printf '-'; return; }
  read -r value < "$1" || { printf '-'; return; }
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '-'
}

valid_percent() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '-'; return; }
  awk -v value="$1" 'BEGIN { if (value >= 0 && value <= 100) print value; else print "-" }'
}

valid_temperature() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '-'; return; }
  awk -v value="$1" 'BEGIN { if (value >= 0 && value <= 125) print value; else print "-" }'
}

temperature() {
  local sensor value
  for sensor in "$1"/hwmon/hwmon*/temp1_input; do
    value=$(read_number "$sensor")
    if [[ "$value" != '-' ]] && (( value >= 1000 && value <= 125000 )); then
      awk -v milli="$value" 'BEGIN { printf "%.1f", milli / 1000 }'
      return
    fi
  done
  printf '-'
}

# A runtime-suspended GPU wakes up when nvidia-smi, lspci or most driver
# attributes touch it, which takes seconds and cannot be interrupted. The PM
# status, vendor and device attributes are safe to read while it sleeps.
suspended() {
  local state
  [[ -r "$1/power/runtime_status" ]] || return 1
  read -r state < "$1/power/runtime_status" || return 1
  [[ "$state" == suspended ]]
}

# Look the name up in the PCI ID database instead of asking lspci, which reads
# the device's configuration space.
pci_name() {
  local vendor=${1#0x} device
  [[ -r "$pci_ids" && -r "$2/device" ]] || return
  read -r device < "$2/device" || return
  device=${device#0x}
  awk -v vendor="${vendor,,}" -v device="${device,,}" '
    /^[[:xdigit:]]{4} / { if (found) exit; found = $1 == vendor; vendor_name = substr($0, 7); next }
    found && index($0, "\t" device " ") == 1 { print vendor_name " " substr($0, 8); exit }
  ' "$pci_ids" 2>/dev/null
}

gpu_name() {
  local device=$1 vendor=$2 name=''
  if [[ -r "$device/product_name" ]]; then
    read -r name < "$device/product_name" || true
  fi
  [[ -n "$name" ]] || name=$(pci_name "$vendor" "$device")
  if [[ -z "${name// /}" ]]; then
    case "$vendor" in
      0x10de) name='NVIDIA GPU' ;;
      0x1002) name='AMD GPU' ;;
      0x8086) name='Intel GPU' ;;
      *) name='DRM GPU' ;;
    esac
    [[ -r "$device/device" ]] && name+=" ($(cat "$device/device"))"
  fi
  clean_field "$name"
}

emit_gpu() {
  printf 'GPU2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:--}"
}

declare -A nvidia_samples=()
declare -A seen=()
declare -a nvidia_order=()
declare -a nvidia_awake=()
declare -a nvidia_asleep=()

for device in "$pci_root"/*; do
  [[ -r "$device/vendor" && -r "$device/class" ]] || continue
  read -r vendor < "$device/vendor"
  read -r class < "$device/class"
  [[ "${vendor,,}" == 0x10de && "$class" == 0x03* ]] || continue
  if suspended "$device"; then nvidia_asleep+=("${device##*/}"); else nvidia_awake+=("${device##*/}"); fi
done

smi_args=("--query-gpu=pci.bus_id,name,utilization.gpu,memory.used,memory.total,temperature.gpu"
  "--format=csv,noheader,nounits")
# Query everything unless a card is asleep; then ask only for the awake ones.
if (( ${#nvidia_asleep[@]} > 0 )); then
  smi_args=(--id="$(IFS=,; printf '%s' "${nvidia_awake[*]}")" "${smi_args[@]}")
fi

if (( ${#nvidia_asleep[@]} == 0 || ${#nvidia_awake[@]} > 0 )) && command -v "$smi" >/dev/null 2>&1; then
  while IFS=',' read -r bus name usage used_mib total_mib temp; do
    bus=$(clean_field "$bus")
    # NVIDIA prints an eight-digit PCI domain; DRM uses four digits.
    [[ "$bus" =~ ^([[:xdigit:]]{4}|[[:xdigit:]]{8}):[[:xdigit:]]{2}:[[:xdigit:]]{2}[.][0-7]$ ]] || continue
    bus=${bus: -12}
    bus=${bus,,}
    name=$(clean_field "$name")
    usage=$(valid_percent "$(clean_field "$usage")")
    used_mib=$(clean_field "$used_mib")
    total_mib=$(clean_field "$total_mib")
    temp=$(clean_field "$temp")
    [[ "$used_mib" =~ ^[0-9]+$ ]] && used_mib=$((used_mib * 1048576)) || used_mib='-'
    [[ "$total_mib" =~ ^[0-9]+$ ]] && total_mib=$((total_mib * 1048576)) || total_mib='-'
    temp=$(valid_temperature "$temp")
    [[ -n "${nvidia_samples[$bus]+x}" ]] || nvidia_order+=("$bus")
    nvidia_samples[$bus]="$name"$'\t'"$usage"$'\t'"$used_mib"$'\t'"$total_mib"$'\t'"$temp"
  done < <(timeout --signal=TERM --kill-after=0.2s 1s "$smi" "${smi_args[@]}" 2>/dev/null)
fi

for card in "$drm_root"/card[0-9]*; do
  [[ -r "$card/device/vendor" ]] || continue
  device=$card/device
  bdf=$(basename "$(readlink -f "$device")")
  [[ "$bdf" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}[.][0-7]$ ]] || continue
  bdf=${bdf,,}
  [[ -n "${seen[$bdf]+x}" ]] && continue
  seen[$bdf]=1
  read -r vendor < "$device/vendor"
  vendor=${vendor,,}
  case "$vendor" in
    0x10de) brand='NVIDIA' ;;
    0x1002) brand='AMD' ;;
    0x8086) brand='Intel' ;;
    *) brand='Other' ;;
  esac
  if suspended "$device"; then
    emit_gpu "$bdf" "$brand" "$(gpu_name "$device" "$vendor")" - - - - suspended
    continue
  fi
  usage='-'; used='-'; total='-'; temp='-'
  if [[ "$vendor" == 0x10de && -n "${nvidia_samples[$bdf]+x}" ]]; then
    IFS=$'\t' read -r name usage used total temp <<< "${nvidia_samples[$bdf]}"
  else
    name=$(gpu_name "$device" "$vendor")
    temp=$(temperature "$device")
    if [[ "$vendor" == 0x1002 ]]; then
      usage=$(read_number "$device/gpu_busy_percent")
      [[ "$usage" == '-' ]] || usage=$(valid_percent "$usage")
      used=$(read_number "$device/mem_info_vram_used")
      total=$(read_number "$device/mem_info_vram_total")
    fi
  fi
  emit_gpu "$bdf" "$brand" "$name" "$usage" "$used" "$total" "$temp"
done

# A compute-only NVIDIA card may have no DRM card node.
for bdf in "${nvidia_order[@]}"; do
  [[ -n "${seen[$bdf]+x}" ]] && continue
  IFS=$'\t' read -r name usage used total temp <<< "${nvidia_samples[$bdf]}"
  emit_gpu "$bdf" NVIDIA "$name" "$usage" "$used" "$total" "$temp"
done

for bdf in "${nvidia_asleep[@]}"; do
  [[ -n "${seen[${bdf,,}]+x}" ]] && continue
  emit_gpu "${bdf,,}" NVIDIA "$(gpu_name "$pci_root/$bdf" 0x10de)" - - - - suspended
done
