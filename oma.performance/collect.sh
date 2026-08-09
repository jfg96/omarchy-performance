#!/usr/bin/env bash

set -u

if (( $# > 1 )); then
  printf 'Expected at most one mode argument\n' >&2
  exit 2
fi

case "${1:---light}" in
  --light) full_sample=false ;;
  --full) full_sample=true ;;
  *)
    printf 'Unknown mode: %s\n' "$1" >&2
    exit 2
    ;;
esac

cpu_total=0
cpu_idle=0
cpu_count=0
while read -r stat_name stat_values; do
  if [[ "$stat_name" == "cpu" ]]; then
    read -r _user _nice _system _idle _iowait _irq _softirq _steal _guest _guest_nice <<< "$stat_values"
    for value in "${_user:-0}" "${_nice:-0}" "${_system:-0}" "${_idle:-0}" "${_iowait:-0}" "${_irq:-0}" "${_softirq:-0}" "${_steal:-0}"; do
      cpu_total=$((cpu_total + value))
    done
    cpu_idle=$((${_idle:-0} + ${_iowait:-0}))
  elif [[ "$stat_name" =~ ^cpu[0-9]+$ ]]; then
    ((cpu_count++))
  fi
done < /proc/stat

# /proc/stat lists every online logical CPU. Keep a fallback for malformed or
# unusually restricted procfs mounts without paying for getconf normally.
if (( cpu_count == 0 )); then
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
fi

mem_total=0
mem_available=0
while read -r key value _unit; do
  case "$key" in
    MemTotal:) mem_total=$value ;;
    MemAvailable:) mem_available=$value ;;
  esac
done < /proc/meminfo

read -r uptime_seconds _uptime_idle < /proc/uptime
page_size=$(getconf PAGESIZE 2>/dev/null || printf '4096')

temp_milli=0
# Prefer the CPU package sensor. Taking the hottest value from every hwmon
# device can accidentally report RAM, NVMe or Wi-Fi temperature as the CPU.
for hwmon in /sys/class/hwmon/hwmon*; do
  [[ -r "$hwmon/name" ]] || continue
  read -r hwmon_name < "$hwmon/name"
  [[ "$hwmon_name" == "coretemp" || "$hwmon_name" == "k10temp" || "$hwmon_name" == "zenpower" ]] || continue
  for label_file in "$hwmon"/temp*_label; do
    [[ -r "$label_file" ]] || continue
    read -r label < "$label_file"
    case "$label" in
      "Package id 0"|Tctl|Tdie|"CPU Package")
        input="${label_file%_label}_input"
        [[ -r "$input" ]] && read -r temp_milli < "$input"
        break 2
        ;;
    esac
  done
done

# Some CPU drivers do not label their package sensor. In that case use the
# hottest value from CPU-specific hwmon devices only.
if ! [[ "$temp_milli" =~ ^[0-9]+$ ]] || (( temp_milli < 1000 || temp_milli > 125000 )); then
  temp_milli=0
  for hwmon in /sys/class/hwmon/hwmon*; do
    [[ -r "$hwmon/name" ]] || continue
    read -r hwmon_name < "$hwmon/name"
    [[ "$hwmon_name" == "coretemp" || "$hwmon_name" == "k10temp" || "$hwmon_name" == "zenpower" ]] || continue
    for input in "$hwmon"/temp*_input; do
      [[ -r "$input" ]] || continue
      read -r value < "$input" || continue
      [[ "$value" =~ ^[0-9]+$ ]] || continue
      (( value >= 1000 && value <= 125000 && value > temp_milli )) && temp_milli=$value
    done
  done
fi

printf 'SYSTEM\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$cpu_total" "$cpu_idle" "${mem_total:-0}" "${mem_available:-0}" \
  "$uptime_seconds" "$temp_milli" "$cpu_count" "$page_size"

disk_mount="/"
disk_total=0
disk_used=0
disk_available=0
{
  read -r _df_header
  read -r _df_source disk_total disk_used disk_available _df_capacity disk_mount
} < <(df -P -B1 / 2>/dev/null)

# / may be a btrfs subvolume with a synthetic major:minor number. Resolve the
# actual block-device source so its cumulative sector counters can be sampled.
disk_read_sectors=0
disk_write_sectors=0
root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
root_source=${root_source%%\[*}
if [[ -n "$root_source" ]]; then
  root_device=$(readlink -f "$root_source" 2>/dev/null || true)
  root_block=${root_device##*/}
  if [[ -r "/sys/class/block/$root_block/stat" ]]; then
    read -r -a disk_stats < "/sys/class/block/$root_block/stat"
    disk_read_sectors=${disk_stats[2]:-0}
    disk_write_sectors=${disk_stats[6]:-0}
  fi
fi

printf 'DISK\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$disk_mount" "$disk_total" "$disk_used" "$disk_available" \
  "$disk_read_sectors" "$disk_write_sectors"

if $full_sample && command -v nvidia-smi >/dev/null 2>&1; then
  if IFS= read -r gpu_line < <(
    nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu \
      --format=csv,noheader,nounits 2>/dev/null
  ); then
    IFS=',' read -r gpu_name gpu_usage gpu_memory_used gpu_memory_total gpu_temperature _gpu_extra <<< "$gpu_line"
    for field_name in gpu_usage gpu_memory_used gpu_memory_total gpu_temperature; do
      field_value=${!field_name}
      while [[ "$field_value" == ' '* ]]; do
        field_value=${field_value# }
      done
      printf -v "$field_name" '%s' "$field_value"
    done
    gpu_name=${gpu_name//$'\t'/ }
    if [[ "$gpu_usage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf 'GPU\t%s\t%s\t%s\t%s\t%s\n' \
        "$gpu_name" "$gpu_usage" "$gpu_memory_used" "$gpu_memory_total" "$gpu_temperature"
    fi
  fi
fi

# In proc(5), utime, stime, starttime and rss are fields 14, 15, 22 and 24.
# After removing fields 1 (pid) and 2 (comm), they are elements 12, 13, 20 and
# 22 of AWK's one-based fields array below. PID + starttime identifies an
# individual process instance.
awk '
  {
    path = $0
    stat = ""
    while ((getline line < path) > 0) {
      if (stat != "") stat = stat "\n"
      stat = stat line
    }
    close(path)
    if (!match(stat, /^([0-9]+) \((.*)\) (.*)$/, part)) next
    pid = part[1]
    comm = part[2]
    count = split(part[3], field, / +/)
    if (count < 22) next

    gsub(/[\t\r\n]/, " ", comm)
    ticks = field[12] + field[13]
    starttime = field[20]
    rss_pages = field[22] + 0
    if (rss_pages < 0) rss_pages = 0
    printf "PROC\t%s\t%s\t%s\t%s\t%s\n", pid, comm, ticks, starttime, rss_pages
  }
' < <(printf '%s\n' /proc/[0-9]*/stat) 2>/dev/null
