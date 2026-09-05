#!/bin/bash
# Load the current bitstream into the FPGA over the USB Blaster (volatile).
set -eu
source "$(dirname "$0")/env.sh"
cd "$PROJ_DIR"
quartus_pgm -m jtag -o "p;output_files/$PROJ.sof" | tail -3
