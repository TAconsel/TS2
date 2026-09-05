# USB audio on the TS2 board

The board is a USB Audio Class 1.0 playback device: the host sends 384 kHz
32-bit stereo over a high-speed isochronous endpoint, and it comes out of the
PCM5102A over I2S.  When nothing is streaming, a 1 kHz test tone plays instead,
so an idle board still proves it is alive.

**This works.**  The device enumerates as `1209:0001 TS2 USB Audio`, ALSA picks
it up as a **high speed** USB-Audio card at `s32le 2ch 384000Hz`, and the full
32-bit sample reaches the I2S bus.  Sustained playback runs with zero dropped
packets and zero FIFO overflows, one isochronous packet per 125 us microframe,
and the feedback loop holding around 48.05 samples per microframe.

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

**High speed, because the rate demands it.**  384 kHz stereo at four bytes a
sample is 3.07 MB/s.  A full-speed frame carries at most 1023 isochronous bytes
-- 1.02 MB/s -- so this format simply does not fit; a high-speed microframe
carries its 384 bytes comfortably.  The device attaches at full speed, because
that is the only way to be seen at all, and negotiates up when the host resets
the bus: it answers with a chirp K, watches for the host to chirp back, and
switches termination if it does.  The register settings for each step come from
the USB3300 datasheet's DP/DM termination table and are listed in
`usb_device.vhd`.

High speed also means the datapath runs at one byte per 60 MHz clock in both
directions, sustained, rather than one byte per forty.  Two of the bugs below
are entirely about that.

**A full 32-bit word to the DAC, which costs a 128 x Fs frame.**  Philips I2S
spends the first bit time of each slot on the format's one-clock delay, so a
32-bit word will not fit a 32-bit slot: at 64 x Fs the most that fits is 31
bits, and the sensible word length is 24.  Sending all 32 means 64 bit clocks
per channel, so BCK is 128 x Fs = 49.1 MHz and the transmitter's clock is
256 x Fs = 98.3 MHz.

Both the word length and the frame size are generics on `ts2_top`, passed to
`i2s_master` and the JTAG monitor together:

| `SLOT_BITS` / `DATA_BITS` | frame | BCK at 384 kHz | |
| --- | --- | --- | --- |
| 64 / 32 | 128 x Fs | 49.1 MHz | full 32-bit (default) |
| 32 / 24 | 64 x Fs | 24.6 MHz | what a PCM5102A wants |

The PCM5102A itself resolves about 19 bits -- 112 dB of dynamic range -- so
bits below the 24th are some 30 dB under its own noise floor and 32-bit output
buys it nothing.  It is there for a converter that can use it.  **If the DAC
will not lock to a 49 MHz bit clock, change the generics to 32 / 24 and the
bit clock halves.**

**SCK is grounded.**  The PCM5102A wants its master clock at 256 x Fs, which at
384 kHz would be another 98.3 MHz pin.  Holding SCK low puts the part in
BCK-only mode, where its own PLL derives the system clock from BCK.

**Asynchronous, with feedback.**  The board's audio clock is 383966.62 Hz --
the closest the PLL reaches from a 50 MHz reference, since the ratio wanted is
3072/3125 and 3125 = 5^5 shares no factor with it -- while the host counts
exact 125 us microframes.  That 87 ppm is 33 samples a second, which drains any
buffer in seconds.  Rather than resample, the device reports the rate it
actually wants on a feedback endpoint and the host varies its packet size, so
the host follows this clock rather than the other way round.  The reported rate
is a measured term (sample ticks counted over 1024 microframes, good to
~20 ppm) plus a correction proportional to how far the FIFO has drifted from
half full.  Being 87 ppm off is therefore not a compromise; it is 0.15 cents of
pitch error and nothing else.

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

## What high speed turned up

Everything at full speed kept working when the rate went up; what broke was
everything that had only ever been exercised at one byte per forty clocks.

* **The transmit prefetch could only refill every other clock.**  Room in the
  buffer was judged without counting the byte the transmitter was taking on the
  same edge, so a fetch was issued, then skipped, then issued.  At full speed,
  where the PHY takes a byte every fortieth clock, that is ample.  At high
  speed it halves the refill rate against a full-rate drain: the buffer empties
  mid-packet, the payload ends early, and every descriptor read fails.
* **Receive packets were framed on the wrong signal.**  The RX CMD's RxActive
  bit is what says a packet is in progress -- except that at high speed this
  PHY delivers a packet's bytes as soon as it takes the bus and only reports
  RxActive afterwards, sometimes after the whole packet.  Framing on it dropped
  seven of every eight start-of-frames.  Framing on DIR, which the PHY holds
  for exactly the duration of a packet, works at both speeds; RxActive going
  false is still honoured, since that is what separates two packets inside one
  DIR window.
* **The Fs counter in the JTAG monitor was 17 bits.**  384 kHz needs 19.  It
  wrapped and reported 121823 Hz, which is wrong in a thoroughly plausible way
  -- the sort of number one might spend an afternoon explaining.

## Resource usage

3,510 of 6,272 logic elements (56%), 100 kbit of 276 kbit of memory (36%), one
of two PLLs, no multipliers.  Roughly a third of that is debug scaffolding:
the JTAG hub and probe, the ULPI bus capture and its 28 kbit buffer, the UART
and the status frame builder.  `DEBUG => false` on `ts2_top` drops the JTAG
monitor; the capture and trace in `usb_top.vhd` would have to go by hand.

| | LE | memory |
| --- | ---: | ---: |
| `usb_device` (ULPI master, SIE, PHY setup, chirp) | 903 | 2 kbit |
| `usb_top` glue: clock search, status frame, snapshot | ~614 | |
| `usb_audio` incl. the dual-clock FIFO | 231 | 49 kbit |
| `ulpi_capture` *(debug)* | 77 | 28 kbit |
| JTAG hub + probe + `i2s_monitor` *(debug)* | ~470 | |
| `i2s_master` | 55 | |
| `tone_gen` + sine ROM | 24 | 4 kbit |
| `uart_tx` *(debug)* | 39 | |
| `led_blink` | 46 | |

## What the first bring-up turned up

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
