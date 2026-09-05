# TS2 — USB audio on a Cyclone 10 LP FPGA

A USB Audio Class playback device built from scratch on a 10CL006YE144C8G core
board: a USB3300 ULPI PHY on one side, a PCM5102A DAC over I2S on the other,
and a full USB device stack in VHDL in between — ULPI bus master, serial
interface engine, control endpoint, descriptors, isochronous audio sink and an
asynchronous feedback loop.

The host sees `1209:0001 TS2 USB Audio`. Samples reach the DAC bit-exact.
When nothing is streaming, a 1 kHz test tone plays so an idle board still
proves it is alive.

See **[USB_AUDIO.md](USB_AUDIO.md)** for the design, the debugging tools, and
an account of what the bring-up turned up.

## Quick start

```sh
scripts/build.sh               # Quartus compile, with a timing summary
scripts/prog.sh                # load over the USB Blaster
scripts/sim.sh                 # both testbenches under GHDL
debug/usb_trace.py --follow    # live status over the board's CH340
```

## Wiring

| Signal | FPGA pin | |
| --- | --- | --- |
| FPGA_CLK | 91 | 50 MHz TCXO |
| LED | 100 | |
| PCM5102A DIN / LCK / BCK / SCK | 1 / 3 / 143 / 141 | |
| USB3300 DATA0..7 | 31 32 33 34 38 39 42 43 | |
| USB3300 STP / NXT / DIR / CLK / RST | 44 / 46 / 49 / 23 / 51 | CLK is a dedicated clock input |
| FPGA_TX | 11 | debug trace, 1 Mbaud, on the on-board CH340 |

The USB3300 module needs its own 3.3 V; the common breakouts do not regulate
it from VBUS, so the OTG cable alone will not power it.
