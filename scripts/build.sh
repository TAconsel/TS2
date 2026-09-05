#!/bin/bash
# Full compile.  Prints only the errors/warnings that matter plus a resource
# and timing summary, so a failed build is obvious without reading the logs.
#   scripts/build.sh
set -u
source "$(dirname "$0")/env.sh"
cd "$PROJ_DIR"

LOG=output_files/build.log
mkdir -p output_files
if ! quartus_sh --flow compile "$PROJ" > "$LOG" 2>&1; then
    echo "=== BUILD FAILED ==="
    grep -E '^(Error|Critical Warning)' "$LOG" | head -40
    exit 1
fi

echo "=== BUILD OK ==="
grep -E '^Critical Warning' "$LOG" | head -20
grep -E 'Total (logic elements|registers|pins|memory bits)|Total PLLs' \
    output_files/$PROJ.fit.summary
echo "--- worst-case slack ---"
awk '/^Type/ {t=$0} /^Slack/ {print $3"\t"t}' output_files/$PROJ.sta.summary \
    | sort -n | head -6
