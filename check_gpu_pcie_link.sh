#!/usr/bin/env bash
set -euo pipefail

# Check PCIe generation, width and estimated bandwidth for GPU devices.
# Output includes a heuristic for x16/x8/PCH x4 classification.

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

need_cmd lspci
need_cmd awk

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
  # Examples: "16.0 GT/s PCIe", "8.0 GT/s"
  echo "$s" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1
}

extract_width_num() {
  local s="$1"
  # Examples: "16", "x16"
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
  # Approx one-way payload per lane (MB/s):
  # Gen1 250, Gen2 500, Gen3 984.6, Gen4 1969.2, Gen5 3938.5, Gen6 7563.1
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

classify_link() {
  local width="$1"
  local upstream="$2"
  local upstream_short="${upstream#0000:}"
  local bus="${upstream_short%%:*}"
  local rest="${upstream_short#*:}"
  local dev_hex="${rest%%.*}"

  local cls="Unknown"
  if [[ "$width" =~ ^[0-9]+$ ]]; then
    if (( width >= 16 )); then
      cls="PCIe x16"
    elif (( width >= 8 )); then
      cls="PCIe x8"
    elif (( width <= 4 )); then
      # Heuristic for desktop Intel platforms:
      # upstream on bus 00 with high device number often maps to PCH root ports.
      if [[ "$bus" == "00" ]]; then
        local dev_dec=$((16#$dev_hex))
        if (( dev_dec >= 0x1b )); then
          cls="PCH x4 (heuristic)"
        else
          cls="PCIe x4 (CPU/PCH unknown)"
        fi
      else
        cls="PCIe x4 (CPU/PCH unknown)"
      fi
    else
      cls="PCIe x${width}"
    fi
  fi

  echo "$cls"
}

get_gpu_lines() {
  lspci -Dnn | awk '/VGA compatible controller|3D controller|Display controller/ {print}'
}

printf "%-12s | %-34s | %-13s | %-13s | %-11s | %-14s | %-24s | %s\n" \
  "GPU BDF" "Device" "Current Link" "Max Link" "Current Gen" "Est BW GB/s" "Class" "Upstream Bridge"
printf "%s\n" "-------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

found=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  found=1

  bdf="$(echo "$line" | awk '{print $1}')"
  short_bdf="${bdf#0000:}"
  dev_name="$(echo "$line" | sed -E 's/^[^ ]+ +//; s/\[[^]]+\]$//')"

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
  max_speed="$(extract_speed_gt "$max_speed_raw")"
  max_width="$(extract_width_num "$max_width_raw")"

  gen="Unknown"
  est_bw="unknown"
  if [[ -n "${curr_speed:-}" && -n "${curr_width:-}" ]]; then
    gen="$(gen_from_speed "$curr_speed")"
    est_bw="$(estimate_bw_gbps "$curr_speed" "$curr_width")"
  fi

  # Parent device in sysfs path is usually the upstream PCIe bridge.
  upstream="$(basename "$(dirname "$(readlink -f "$sysdev")")")"
  upstream_short="${upstream#0000:}"
  cls="$(classify_link "${curr_width:-0}" "$upstream")"

  printf "%-12s | %-34.34s | %-13s | %-13s | %-11s | %-14s | %-24s | %s\n" \
    "$short_bdf" "$dev_name" \
    "${curr_speed_raw:-unknown} x${curr_width_raw:-?}" \
    "${max_speed_raw:-unknown} x${max_width_raw:-?}" \
    "$gen" "$est_bw" "$cls" "$upstream_short"
done < <(get_gpu_lines)

if [[ $found -eq 0 ]]; then
  echo "No GPU-like PCI devices found by lspci."
  exit 1
fi

echo
echo "Notes:"
echo "- Est BW GB/s = one-way/two-way theoretical payload bandwidth (approx)."
echo "- PCH x4 classification is heuristic based on upstream bridge position; verify with motherboard slot map/manual."
