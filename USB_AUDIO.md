# USB audio on the TS2 board

The board is a USB Audio Class 1.0 playback device: the host sends 48 kHz
16-bit stereo over an isochronous endpoint, and it comes out of the PCM5102A
over I2S.  When nothing is streaming, the original 1 kHz test tone plays
instead, so an idle board still proves it is alive.

**This works.**  The device enumerates as `1209:0001 TS2 USB Audio`, ALSA picks
it up as a full-speed USB-Audio card, and samples arrive at the DAC bit-exact:
writing +0x4000 to the left channel and -0x4000 to the right produces exactly
0x400000 and -0x400000 in the I2S stream.  Sustained playback runs with zero
dropped packets and zero FIFO overflows, one isochronous packet per USB frame,
and the feedback loop holding between 47.99 and 48.07 samples per frame.

## Layout

| File | What it is |
| --- | --- |
| `ts2_top.vhd` | top level; picks USB audio or the test tone |
| `usb_top.vhd` | USB subsystem: PHY clock search, trace, capture, device |
| `usb_device.vhd` | PHY register setup + ULPI master + SIE |
| `ulpi.vhd` | ULPI bus master: register access, packet in and out, CRC16 |
| `usb_sie.vhd` | packet and transaction layer, endpoint 0, control transfers |
| `usb_desc.vhd` | descriptor ROM, **generated** by `scripts/gen_descriptors.py` |
| `usb_audio.vhd` | isochronous sink, clock crossing, feedback loop |
| `ulpi_capture.vhd` | cycle-level ULPI bus capture, dumped over the UART |
| `async_fifo.vhd` | dual-clock FIFO used by the audio path |
| `uart_tx.vhd` | 1 Mbaud trace output on the CH340 |

Three clock domains, none related: the 50 MHz TCXO, the PHY's 60 MHz, and the
audio PLL's 12.288 MHz.  Every crossing goes through a resynchroniser, a
dual-clock FIFO, or the snapshot handshake in `usb_top.vhd`.

## Working on it

```sh
scripts/sim.sh                 # both testbenches under GHDL
scripts/build.sh               # full Quartus compile, with a timing summary
scripts/prog.sh                # load the bitstream over the USB Blaster
debug/usb_trace.py --follow    # live status over /dev/ttyUSB0
debug/usb_trace.py -v -c       # add the sweep detail and the bus capture
debug/i2s_debug.sh             # decode the live I2S bus over JTAG
python3 scripts/gen_descriptors.py   # after changing the audio format
```

`scripts/sim.sh` needs GHDL (`apt install ghdl`), installed while working on
this because without hardware it was the only way to test anything.

To play something:

```sh
pactl list short sinks | grep TS2
paplay --device=alsa_output.usb-TS2_TS2_USB_Audio-00.analog-stereo file.wav
```

PipeWire claims the card, so `aplay -D hw:...` will report the device busy.

## Design notes

**Full speed, not high speed.**  One 1 ms frame carries up to 1023
isochronous bytes; 48 kHz 16-bit stereo needs 192.  High speed would buy
nothing and cost the chirp handshake plus a one-byte-per-clock datapath.

**Asynchronous, with feedback.**  The board's audio clock is 48000.53 Hz --
the closest the PLL reaches from 50 MHz -- while the host counts exact 1 ms
frames.  That 11 ppm is half a sample a second, which drains any buffer
eventually.  Rather than resample, the device reports the rate it actually
wants on a feedback endpoint and the host varies its packet size.  The
reported rate is a measured term (sample ticks counted over 1024 frames, good
to ~20 ppm) plus a correction proportional to how far the FIFO has drifted
from half full.

**Playback waits for the buffer.**  Nothing is sent to the DAC until the FIFO
reaches its target, about 5 ms.  Starting into an empty buffer means a few
milliseconds of repeated samples at the top of every stream -- an audible
click, and a burst of underruns in the statistics.

**ULPI timing is tight.**  The PHY presents data up to 9 ns after its clock
edge and needs 6 ns of setup back, leaving ~1.7 ns of the 16.7 ns cycle.  The
ULPI registers are packed into the I/O cells, and the data output register
feeds nothing but the pin (the CRC reads a separate copy) so the fitter is
able to pack it.  `ulpi_clk` is on PIN_23, a dedicated clock input: on a
general I/O pin the trip to the global clock network cost about 3.3 ns of
skew and setup closed at only +0.03 ns.  It now closes at about +0.8 ns.

Two paths to the pins are false-pathed, with the reasoning in `TS2.sdc`.  Both
are the tri-state enable, which is not a data path.

## What the bring-up turned up

Everything below was found on hardware with `ulpi_capture.vhd` and then
reproduced in simulation before being fixed, so the testbenches now catch each
one.  All four were invisible from the status counters: the device looked like
it was working while the host rejected everything.

* **The PHY takes bytes on consecutive clocks.**  It asserts NXT across two
  cycles for a register write -- command in the first, data in the second --
  and swallows a packet's command plus its first two payload bytes back to
  back before throttling to full-speed rates.  Reacting to a registered copy
  of NXT is one cycle too slow, so the byte still on the bus goes out twice.
  That wrote the command byte into every register, and doing that to Function
  Control clears SuspendM and puts the PHY to sleep -- which presented as a
  PHY that would not keep its clock running.  Flow control now reads the NXT
  pin directly, and the transmit acknowledgement is combinational.
* **A descriptor memory cannot answer that on its own.**  Transmitted bytes
  come from a four-byte prefetch buffer filled three ahead, or the first bytes
  of every descriptor go out duplicated.
* **The PHY pre-empts the link whenever the USB lines change**, which happens
  the instant the pull-downs are cleared.  An aborted register transfer used
  to leave the requester waiting forever; aborts are now reported and retried.
* **A PHY reset does not disconnect.**  0x45 -- pull-up on -- is the reset
  value of Function Control, so the setup sequence explicitly writes
  TermSelect = 0, waits 20 ms, then writes it back.  Without a real
  disconnect, a host that has given up on the port never tries again.

The clock search in `usb_top.vhd` also learned to require the PHY to answer a
register read rather than merely to produce clock edges: the USB3300 runs its
crystal and PLL independently of its logic reset, so a part held in reset
drives a perfectly good 60 MHz while answering nothing.

## Debugging tools

`debug/usb_trace.py` decodes a status frame the board emits every ~240 ms:
clock health, the reset/STP sweep, PHY register readbacks, USB state, SOF and
packet counters, FIFO health and the feedback rate.  With `-c` it also decodes
a cycle-level capture of the ULPI bus.

The capture records only transitions, with the cycle count each state lasted,
and masks the line-state bits of RX CMDs -- the PHY reports every J-to-K
transition on the wire, which during a packet is one per bit and would
otherwise fill the buffer several times over in a single transfer.  It
triggers on a chosen received byte, by default the SETUP PID, so a whole
control transfer is captured from its first packet.  Reading a full-speed
transaction out of it is what found every bug above.
