#!/bin/bash
# Run the USB testbenches under GHDL.
#   scripts/sim.sh [device|audio]      (default: both)
set -u
cd "$(dirname "$0")/.."
WORK=/tmp/claude-1000/-home-consel-TS2/4258c082-7b78-44f4-a03e-083885796665/scratchpad/ghdl
mkdir -p "$WORK"
F="--std=93 --ieee=synopsys -fexplicit --workdir=$WORK"
set -e
ghdl -a $F usb_desc.vhd ulpi.vhd usb_sie.vhd usb_device.vhd async_fifo.vhd \
          usb_audio.vhd tb/tb_usb_device.vhd tb/tb_usb_audio.vhd 2>&1 \
    | grep -v -- '-Whide' | grep -v '^ *procedure send_packet' | grep -v '^ *\^' || true

run () {
    echo "=============== $1 ==============="
    ghdl -e $F "$1"
    # The mcode backend runs the design in place rather than linking a binary.
    ghdl -r $F "$1" --stop-time="$2"
}

case "${1:-both}" in
    device) run tb_usb_device 20ms ;;
    audio)  run tb_usb_audio  80ms ;;
    *)      run tb_usb_device 20ms; run tb_usb_audio 80ms ;;
esac
