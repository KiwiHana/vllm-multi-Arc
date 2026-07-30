#!/usr/bin/env bash
set -euo pipefail

# Check PCIe generation, width and estimated bandwidth for GPU devices.
# Also walk the PCI ancestry so we can report whether a GPU is more likely
# CPU-direct or hanging off a PCH root port.

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

need_cmd lspci
need_cmd awk
need_cmd grep
need_cmd sed

read_sysfs_value() {
  local path="$1"
  if [[ -r "$path" ]]; then
    tr -d '\n' < "$path"
  else
    echo "unknown"
  fi
}

extract_speed_gt() {
  local s="$1"
  echo "$s" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1
}

extract_width_num() {
  local s="$1"
  echo "$s" | grep -oE '[0-9]+' | head -n1
}

gen_from_speed() {
  local speed="$1"
  awk -v s="$speed" 'BEGIN {
    if (s >= 64) print "Gen6";
    else if (s >= 32) print "Gen5";
    else if (s >= 16) print "Gen4";
    else if (s >= 8) print "Gen3";
    else if (s >= 5) print "Gen2";
    else if (s >= 2.5) print "Gen1";
    else print "Unknown";
  }'
}

lane_mb_per_s() {
  local speed="$1"
  awk -v s="$speed" 'BEGIN {
    if (s >= 64) print 7563.1;
    else if (s >= 32) print 3938.5;
    else if (s >= 16) print 1969.2;
    else if (s >= 8) print 984.6;
    else if (s >= 5) print 500.0;
    else if (s >= 2.5) print 250.0;
    else print 0.0;
  }'
}

estimate_bw_gbps() {
  local speed="$1"
  local width="$2"
  local lane_mb
  lane_mb="$(lane_mb_per_s "$speed")"
  awk -v mb="$lane_mb" -v w="$width" 'BEGIN {
    one_way_gb = (mb * w) / 1024.0;
    two_way_gb = one_way_gb * 2.0;
    printf "%.2f/%.2f", one_way_gb, two_way_gb;
  }'
}

get_gpu_lines() {
  lspci -Dnn | awk '/VGA compatible controller|3D controller|Display controller/ {print}'
}

get_device_desc() {
  local bdf="$1"
  local desc
  desc="$(lspci -Dnn -s "$bdf" 2>/dev/null | sed -E 's/^[^ ]+ +//')"
  echo "${desc:-unknown}"
}

get_pci_chain() {
  local sysdev="$1"
  local resolved
  resolved="$(readlink -f "$sysdev")"
  echo "$resolved" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' || true
}

get_root_port() {
  local sysdev="$1"
  local chain
  chain="$(get_pci_chain "$sysdev")"
  echo "$chain" | head -n1
}

get_immediate_upstream() {
  local sysdev="$1"
  basename "$(dirname "$(readlink -f "$sysdev")")"
}

format_chain() {
  local chain="$1"
  echo "$chain" | sed 's/^0000://' | awk 'BEGIN { first=1 } { if (!first) printf " -> "; printf "%s", $0; first=0 } END { printf "\n" }'
}

classify_root_port() {
  local root_port="$1"
  if [[ -z "$root_port" ]]; then
    echo "Unknown (root port not found)"
    return 0
  fi
  local root_short="${root_port#0000:}"
  local bus="${root_short%%:*}"
  local rest="${root_short#*:}"
  local dev_hex="${rest%%.*}"
  local fn="${rest#*.}"
  local dev_dec=$((16#$dev_hex))

  if [[ "$bus" != "00" ]]; then
    echo "Unknown (non-bus00 root)"
    return 0
  fi

  case "${dev_hex}.${fn}" in
    01.0|01.1|01.2|01.3|06.0|06.2|06.4)
      echo "Likely CPU-direct PCIe"
      return 0
      ;;
    1b.*|1c.*|1d.*)
      echo "Likely via PCH"
      return 0
      ;;
  esac

  if (( dev_dec >= 0x1b )); then
    echo "Likely via PCH"
  elif (( dev_dec <= 0x06 )); then
    echo "Likely CPU-direct PCIe"
  else
    echo "Unknown (check board manual)"
  fi
}

printf "%-12s | %-18s | %-11s | %-13s | %-13s | %-18s | %-22s | %s\n" \
  "GPU BDF" "Current Gen" "Est BW GB/s" "Root Port" "Immediate Up" "Topology Guess" "Link" "GPU Device"
printf "%s\n" "-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

found=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  found=1

  bdf="$(echo "$line" | awk '{print $1}')"
  short_bdf="${bdf#0000:}"
  dev_name="$(echo "$line" | sed -E 's/^[^ ]+ +//')"

  sysdev="/sys/bus/pci/devices/$bdf"
  if [[ ! -d "$sysdev" ]]; then
    continue
  fi

  curr_speed_raw="$(read_sysfs_value "$sysdev/current_link_speed")"
  curr_width_raw="$(read_sysfs_value "$sysdev/current_link_width")"
  max_speed_raw="$(read_sysfs_value "$sysdev/max_link_speed")"
  max_width_raw="$(read_sysfs_value "$sysdev/max_link_width")"

  curr_speed="$(extract_speed_gt "$curr_speed_raw")"
  curr_width="$(extract_width_num "$curr_width_raw")"

  gen="Unknown"
  est_bw="unknown"
  if [[ -n "${curr_speed:-}" && -n "${curr_width:-}" ]]; then
    gen="$(gen_from_speed "$curr_speed")"
    est_bw="$(estimate_bw_gbps "$curr_speed" "$curr_width")"
  fi

  chain="$(get_pci_chain "$sysdev")"
  root_port="$(get_root_port "$sysdev")"
  root_short="${root_port#0000:}"
  immediate_up="$(get_immediate_upstream "$sysdev")"
  immediate_short="${immediate_up#0000:}"
  topo_guess="$(classify_root_port "$root_port")"

  printf "%-12s | %-18s | %-11s | %-13s | %-13s | %-18s | %-22s | %s\n" \
    "$short_bdf" \
    "$gen" \
    "$est_bw" \
    "$root_short" \
    "$immediate_short" \
    "$topo_guess" \
    "${curr_speed_raw:-unknown} x${curr_width_raw:-?}" \
    "$dev_name"

  echo "  Max Link     : ${max_speed_raw:-unknown} x${max_width_raw:-?}"
  echo "  Root Port    : $(get_device_desc "$root_port")"
  echo "  Upstream Path: $(format_chain "$chain")"
  echo
done < <(get_gpu_lines)

if [[ $found -eq 0 ]]; then
  echo "No GPU-like PCI devices found by lspci."
  exit 1
fi

echo "Notes:"
echo "- Topology Guess is heuristic and based on the root port BDF, not just the immediate upstream bridge."
echo "- 'Likely CPU-direct PCIe' usually means the GPU ultimately hangs from a CPU root port such as 00:01.x/00:06.x."
echo "- 'Likely via PCH' usually means the GPU ultimately hangs from a PCH root port such as 00:1b.x/00:1c.x/00:1d.x."
echo "- If the result is 'Unknown', confirm with the motherboard manual and 'lspci -tv'."
