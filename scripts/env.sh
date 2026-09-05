# Common environment for the helper scripts.  Sourced, not run.
QBIN="${QBIN:-$HOME/intelFPGA_lite/23.1std/quartus/bin}"
PROJ_DIR="${PROJ_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJ="${PROJ:-TS2}"
export PATH="$QBIN:$PATH"
