#!/bin/sh
# Read and decode the live I2S bus over JTAG.  Usage: debug/i2s_debug.sh [reads]
set -e
QBIN="${QBIN:-$HOME/intelFPGA_lite/23.1std/quartus/bin}"
HERE=$(dirname "$0")
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
"$QBIN/quartus_stp_tcl" -t "$HERE/read_i2s.tcl" "${1:-8}" \
    | grep -E '^(HW|DEV|INFO|PROBE|ERROR)' | tee "$OUT"
echo
python3 "$HERE/decode_i2s.py" "$OUT"
