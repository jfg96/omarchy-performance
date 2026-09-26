#!/usr/bin/env bash

set -u
proc_root=${PERFORMANCE_PROC_ROOT:-/proc}
printf 'GPU_ACTIVITY\n'

# DRM fdinfo reports per-client busy time. Deduplicate shared file descriptors
# by device/client ID; the model derives a rate from consecutive snapshots.
awk '
  {
    path = $0
    driver = pdev = client = ""
    delete busy
    delete capacity
    while ((getline line < path) > 0) {
      if (line !~ /^drm-/) continue
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
