#!/usr/bin/env python3
"""Generate usb_desc.vhd, the USB descriptor ROM for the audio device.

Run from the project root:  python3 scripts/gen_descriptors.py

Descriptors are built here rather than written out as hex so that every
bLength and wTotalLength is computed from the structure instead of counted by
hand -- a wrong length is the classic way to make a device that enumerates
almost correctly and then fails in a way that is very hard to see from the
FPGA side.

The device is a USB Audio Class 1.0 playback sink: 48 kHz, 16-bit, stereo, on
an isochronous OUT endpoint, with an explicit feedback endpoint so the host
can follow the board's own audio clock (which is 48000.53 Hz, not 48000).
"""

# ---------------------------------------------------------------- constants
VENDOR_ID = 0x1209      # pid.codes, the open-source VID
PRODUCT_ID = 0x0001     # their "for testing only" PID

SAMPLE_RATE = 48000
CHANNELS = 2
BYTES_PER_SAMPLE = 2    # 16-bit
BITS = 16

# One frame of audio plus a sample of slack, since an asynchronous sink is
# asked for a varying number of samples per frame.
AUDIO_MAX_PACKET = (SAMPLE_RATE // 1000 + 1) * CHANNELS * BYTES_PER_SAMPLE

EP_AUDIO_OUT = 0x01
EP_FEEDBACK_IN = 0x81

# Descriptor types
DEVICE, CONFIG, STRING, INTERFACE, ENDPOINT = 1, 2, 3, 4, 5
CS_INTERFACE, CS_ENDPOINT = 0x24, 0x25

# Audio class
AUDIO, AUDIOCONTROL, AUDIOSTREAMING = 1, 1, 2
AC_HEADER, AC_INPUT_TERMINAL, AC_OUTPUT_TERMINAL = 1, 2, 3
AS_GENERAL, AS_FORMAT_TYPE = 1, 2
EP_GENERAL = 1


def u8(v):
    return [v & 0xFF]


def u16(v):
    return [v & 0xFF, (v >> 8) & 0xFF]


def u24(v):
    return [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF]


def desc(type_, *fields):
    """A descriptor whose bLength is filled in from its actual size."""
    body = [b for f in fields for b in f]
    return [len(body) + 2, type_] + body


# ---------------------------------------------------------------- device
device = desc(
    DEVICE,
    u16(0x0110),          # bcdUSB 1.10
    u8(0),                # bDeviceClass: per-interface
    u8(0),                # bDeviceSubClass
    u8(0),                # bDeviceProtocol
    u8(64),               # bMaxPacketSize0
    u16(VENDOR_ID),
    u16(PRODUCT_ID),
    u16(0x0100),          # bcdDevice
    u8(1),                # iManufacturer
    u8(2),                # iProduct
    u8(0),                # iSerialNumber
    u8(1),                # bNumConfigurations
)

# ------------------------------------------------- audio control interface
ac_interface = desc(
    INTERFACE,
    u8(0),                # bInterfaceNumber
    u8(0),                # bAlternateSetting
    u8(0),                # bNumEndpoints
    u8(AUDIO), u8(AUDIOCONTROL), u8(0),
    u8(0),                # iInterface
)

# Terminal chain: USB stream (ID 1) -> speaker (ID 3).
input_terminal = desc(
    CS_INTERFACE,
    u8(AC_INPUT_TERMINAL),
    u8(1),                # bTerminalID
    u16(0x0101),          # wTerminalType: USB streaming
    u8(0),                # bAssocTerminal
    u8(CHANNELS),         # bNrChannels
    u16(0x0003),          # wChannelConfig: front left + front right
    u8(0),                # iChannelNames
    u8(0),                # iTerminal
)

output_terminal = desc(
    CS_INTERFACE,
    u8(AC_OUTPUT_TERMINAL),
    u8(3),                # bTerminalID
    u16(0x0301),          # wTerminalType: speaker
    u8(0),                # bAssocTerminal
    u8(1),                # bSourceID: the input terminal
    u8(0),                # iTerminal
)

# The header's wTotalLength covers itself and every class-specific descriptor
# that follows in this interface, so it has to be built last and patched.
ac_header = desc(
    CS_INTERFACE,
    u8(AC_HEADER),
    u16(0x0100),          # bcdADC 1.00
    u16(0),               # wTotalLength, patched below
    u8(1),                # bInCollection: one streaming interface
    u8(1),                # baInterfaceNr(1)
)
ac_total = len(ac_header) + len(input_terminal) + len(output_terminal)
ac_header[5:7] = u16(ac_total)

# ----------------------------------------------- audio streaming interface
# Alternate setting 0 has no endpoint at all: that is how the host parks the
# interface and stops reserving isochronous bandwidth when nothing is playing.
as_interface_0 = desc(
    INTERFACE,
    u8(1), u8(0), u8(0),
    u8(AUDIO), u8(AUDIOSTREAMING), u8(0),
    u8(0),
)

as_interface_1 = desc(
    INTERFACE,
    u8(1), u8(1), u8(2),      # two endpoints: audio out and feedback in
    u8(AUDIO), u8(AUDIOSTREAMING), u8(0),
    u8(0),
)

as_general = desc(
    CS_INTERFACE,
    u8(AS_GENERAL),
    u8(1),                # bTerminalLink: the input terminal
    u8(1),                # bDelay, in frames
    u16(0x0001),          # wFormatTag: PCM
)

as_format = desc(
    CS_INTERFACE,
    u8(AS_FORMAT_TYPE),
    u8(1),                # bFormatType: type I
    u8(CHANNELS),
    u8(BYTES_PER_SAMPLE),
    u8(BITS),
    u8(1),                # bSamFreqType: one discrete rate
    u24(SAMPLE_RATE),
)

# Audio endpoint descriptors carry two extra bytes over the standard five.
# bmAttributes 0x05 is isochronous + asynchronous: the device runs off its own
# clock and tells the host what rate it actually wants via the feedback
# endpoint named in bSynchAddress.
ep_audio = desc(
    ENDPOINT,
    u8(EP_AUDIO_OUT),
    u8(0x05),
    u16(AUDIO_MAX_PACKET),
    u8(1),                # bInterval: every frame
    u8(0),                # bRefresh
    u8(EP_FEEDBACK_IN),   # bSynchAddress
)

ep_audio_cs = desc(
    CS_ENDPOINT,
    u8(EP_GENERAL),
    u8(0x00),             # bmAttributes: no sampling frequency control, so the
                          # host never asks us to change rate
    u8(0),                # bLockDelayUnits
    u16(0),               # wLockDelay
)

# bmAttributes 0x11 is isochronous with usage type "feedback".  bRefresh 3
# means the host reads it every 2**3 = 8 frames, which is slow enough to be
# cheap and fast enough to track a drifting clock.
ep_feedback = desc(
    ENDPOINT,
    u8(EP_FEEDBACK_IN),
    u8(0x11),
    u16(3),               # wMaxPacketSize: a 10.14 rate in three bytes
    u8(1),                # bInterval
    u8(3),                # bRefresh: every 8 frames
    u8(0),                # bSynchAddress
)

config_body = (
    ac_interface + ac_header + input_terminal + output_terminal
    + as_interface_0
    + as_interface_1 + as_general + as_format
    + ep_audio + ep_audio_cs + ep_feedback
)

config = desc(
    CONFIG,
    u16(0),               # wTotalLength, patched below
    u8(2),                # bNumInterfaces
    u8(1),                # bConfigurationValue
    u8(0),                # iConfiguration
    u8(0x80),             # bmAttributes: bus powered, no remote wakeup
    u8(50),               # bMaxPower: 100 mA
) + config_body
config[2:4] = u16(len(config))


def string_desc(text):
    body = []
    for ch in text:
        body += u16(ord(ch))
    return [len(body) + 2, STRING] + body


strings = [
    [4, STRING, 0x09, 0x04],          # 0: language list, US English
    string_desc("TS2"),               # 1: iManufacturer
    string_desc("TS2 USB Audio"),     # 2: iProduct
]

# ---------------------------------------------------------------- emit
blocks = [("DEVICE", device), ("CONFIG", config)]
blocks += [(f"STRING{i}", s) for i, s in enumerate(strings)]

rom = []
locs = {}
for name, data in blocks:
    locs[name] = (len(rom), len(data))
    rom += data

# The ROM address is a plain unsigned; round the depth up so the range is a
# power of two and Quartus infers a memory block rather than logic.
depth = 1
while depth < len(rom):
    depth *= 2

# VHDL aggregates cannot mix positional and named elements, so the padding is
# written out as ordinary zero bytes rather than an "others" clause.
padded = rom + [0] * (depth - len(rom))
lines = []
for i in range(0, len(padded), 8):
    chunk = ", ".join(f'x"{b:02X}"' for b in padded[i : i + 8])
    lines.append(f"        {chunk},")
lines[-1] = lines[-1].rstrip(",")

sel = []
for name, (off, ln) in locs.items():
    sel.append(f"    constant {name}_OFF : natural := {off};")
    sel.append(f"    constant {name}_LEN : natural := {ln};")

vhdl = f'''library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Generated by scripts/gen_descriptors.py -- do not edit by hand.
--
-- USB Audio Class 1.0 playback sink: {SAMPLE_RATE} Hz, {BITS}-bit, {CHANNELS} channels, on an
-- isochronous OUT endpoint of {AUDIO_MAX_PACKET} bytes, with an asynchronous feedback
-- endpoint so the host follows the board's audio clock instead of the other
-- way round.
--
-- Total ROM: {len(rom)} bytes in a {depth}-byte memory.

package usb_desc is

{chr(10).join(sel)}

    constant DESC_ADDR_BITS : natural := {depth.bit_length() - 1};
    constant EP_AUDIO_OUT   : natural := {EP_AUDIO_OUT};
    constant EP_FEEDBACK_IN : natural := {EP_FEEDBACK_IN & 0x0F};
    constant AUDIO_MAX_PACKET : natural := {AUDIO_MAX_PACKET};

    type desc_rom_t is array (0 to {depth - 1}) of STD_LOGIC_VECTOR(7 downto 0);

    constant DESC_ROM : desc_rom_t := (
{chr(10).join(lines)}
    );

end package usb_desc;
'''

with open("usb_desc.vhd", "w") as f:
    f.write(vhdl)

print(f"usb_desc.vhd: {len(rom)} bytes of descriptor in a {depth}-byte ROM")
for name, (off, ln) in locs.items():
    print(f"  {name:9s} offset {off:4d}  length {ln}")
print(f"  audio max packet {AUDIO_MAX_PACKET} bytes")
