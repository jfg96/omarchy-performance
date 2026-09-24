#!/usr/bin/env bash

set -u

# The root override allows fixture tests without touching the host's sysfs.
drm_root=${PERFORMANCE_DRM_ROOT:-/sys/class/drm}
proc_root=${PERFORMANCE_PROC_ROOT:-/proc}
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

gpu_name() {
  local device=$1 vendor=$2 bdf=$3 name='' label
  if [[ -r "$device/product_name" ]]; then
    read -r name < "$device/product_name" || true
  fi
  if [[ -z "$name" ]] && command -v lspci >/dev/null 2>&1; then
    label=$(lspci -s "$bdf" -mm 2>/dev/null | head -1)
    name=$(awk -F '"' '{print $4 " " $6}' <<< "$label")
  fi
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
  printf 'GPU2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

declare -A nvidia_samples=()
declare -A seen=()
declare -a nvidia_order=()

if command -v "$smi" >/dev/null 2>&1; then
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
  done < <("$smi" --query-gpu=pci.bus_id,name,utilization.gpu,memory.used,memory.total,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null)
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
  name=$(gpu_name "$device" "$vendor" "$bdf")
  usage='-'; used='-'; total='-'; temp='-'
  if [[ "$vendor" == 0x10de && -n "${nvidia_samples[$bdf]+x}" ]]; then
    IFS=$'\t' read -r name usage used total temp <<< "${nvidia_samples[$bdf]}"
  else
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

# DRM fdinfo reports per-client busy time. Deduplicate shared file descriptors
# by device/client ID; the model derives a rate from consecutive snapshots.
awk '
  {
    path = $0
    driver = pdev = client = ""
    delete busy
    delete capacity
    while ((getline line < path) > 0) {
      split(line, pair, ":")
      key = pair[1]
      value = substr(line, length(key) + 2)
      sub(/^[ \t]+/, "", value)
      if (key == "drm-driver") driver = value
      else if (key == "drm-pdev") pdev = value
      else if (key == "drm-client-id") client = value
      else if (key ~ /^drm-engine-capacity-/ && value ~ /^[0-9]+$/)
        capacity[substr(key, 21)] = value + 0
      else if (key ~ /^drm-engine-/ && value ~ /^[0-9]+ ns$/)
        busy[substr(key, 12)] = value + 0
    }
    close(path)
    if (driver == "" || pdev !~ /^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}[.][0-7]$/ || client !~ /^[0-9]+$/) next
    for (engine in busy) {
      id = tolower(pdev) SUBSEP client SUBSEP engine
      if (!(id in totals) || busy[engine] > totals[id]) totals[id] = busy[engine]
      caps[id] = capacity[engine] > 0 ? capacity[engine] : 1
      devices[id] = tolower(pdev)
      clients[id] = client
      engines[id] = engine
    }
  }
  END {
    for (id in totals)
      printf "GPUCLIENT\t%s\t%s\t%s\t%.0f\t%d\n", devices[id], clients[id], engines[id], totals[id], caps[id]
  }
' < <(printf '%s\n' "$proc_root"/[0-9]*/fdinfo/*) 2>/dev/null
