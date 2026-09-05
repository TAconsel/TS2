#!/usr/bin/env python3
"""Decode the USB status frame from the board's CH340.

    debug/usb_trace.py [--port /dev/ttyUSB0] [--count N] [--follow]

The FPGA emits a fixed 47-byte frame every ~240 ms; see usb_top.vhd for the
layout.  Frames are found by their 0x55 0xAA magic, so starting mid-frame just
costs one frame of resync.
"""
import argparse
import sys
import time

import serial

MAGIC = b"\x55\xaa"
FRAME = 47
CAP_MAGIC = b"\x55\xbb"
CAP_SAMPLES = 1024
CAP_BYTES = 2 + CAP_SAMPLES * 4

LINESTATE = {0: "SE0", 1: "J", 2: "K", 3: "SE1"}
PIDS = {
    0x1: "OUT", 0x9: "IN", 0x5: "SOF", 0xD: "SETUP",
    0x3: "DATA0", 0xB: "DATA1", 0x2: "ACK", 0xA: "NAK", 0xE: "STALL",
}
# ULPI RX CMD bits [3:2].  For a bus-powered device the interesting question is
# simply whether the host's VBUS is there at all.
VBUS = {
    0: "none",
    1: "above SessEnd",
    2: "above SessValid",
    3: "VbusValid (host powered)",
}
COMBOS = ["RST=0 STP=0", "RST=0 STP=1", "RST=1 STP=0", "RST=1 STP=1"]


def decode(f):
    u16 = lambda i: f[i] | (f[i + 1] << 8)
    u24 = lambda i: f[i] | (f[i + 1] << 8) | (f[i + 2] << 16)
    flags, uflags = f[12], f[13]
    # The clock witness toggles once per 128 ULPI clocks over a 100 ms window,
    # so 60 MHz reads back as 46875 counts.
    hz = lambda c: c * 128 * 10
    return {
        "ulpi_hz": hz(u16(2)),
        "combo_hz": [hz(u16(4 + 2 * i)) for i in range(4)],
        "run_level": flags & 1,
        "phy_go": (flags >> 1) & 1,
        "id_ok": (flags >> 2) & 1,
        "clock_seen": (flags >> 3) & 1,
        "combo": (flags >> 4) & 3,
        "phy_ready": uflags & 1,
        "configured": (uflags >> 1) & 1,
        "streaming": (uflags >> 2) & 1,
        "playing": (uflags >> 3) & 1,
        "linestate": LINESTATE[(uflags >> 4) & 3],
        "reset_seen": (uflags >> 6) & 1,
        "dev_addr": f[14] & 0x7F,
        "frame_no": u16(15) & 0x7FF,
        # Counters are reset once per status frame, so the window is the
        # 200 ms between frames, not the 100 ms measurement window.
        "sof_per_frame": u16(17),
        "pkt_per_frame": u16(19),
        "drops": f[21],
        "setups": f[22],
        "txs": f[23],
        "fb": u24(24),
        "beat": f[27],
        "pin_level": f[28] | (f[29] << 8),
        "pin_tog": f[30] | (f[31] << 8),
        "read_a5": f[32],
        "read_5a": f[33],
        "srch": f[44] >> 5,
        "idle_win": f[44] & 31,
        "over": f[45],
        "under": f[46],
        "probes": [(f[34] >> i) & 1 for i in range(4)],
        "vid": f[35],
        "init_step": f[36] & 15,
        "pid": f[40],
        "scratch": [f[41], f[42], f[43]],
        "func": f[37],
        "otg": f[38],
        "line_now": LINESTATE[f[39] & 3],
        "vbus_now": VBUS[(f[39] >> 2) & 3],
    }


def show(d, verbose):
    state = "LOCKED" if d["phy_go"] and d["clock_seen"] else (
        "searching combo %d" % d["combo"])
    print(
        f"beat {d['beat']:3d}  ULPI clk {d['ulpi_hz'] / 1e6:6.2f} MHz  {state}"
        f"{'' if d['clock_seen'] else '   (PHY never clocked)'}"
    )
    if not d["clock_seen"] or verbose:
        print(
            "    reset/STP sweep: "
            + "  ".join(
                f"{c} {h / 1e6:.1f}MHz/{'answered' if p else 'silent'}"
                for c, h, p in zip(COMBOS, d["combo_hz"], d["probes"])
            )
        )
        print(
            f"    vendor id byte {d['vid']:#04x} "
            f"({'SMSC' if d['vid'] == 0x24 else 'not SMSC'}), "
            f"setup reached step {d['init_step']} of 11"
        )
        want = [0xFF, 0x55, 0xAA]
        walk = "  ".join(
            f"{w:#04x}->{g:#04x}{'' if w == g else ' BAD'}"
            for w, g in zip(want, d["scratch"])
        )
        stuck = 0
        for w, g in zip(want, d["scratch"]):
            stuck |= w ^ g
        print(f"    data bus walk (scratch reg): {walk}")
        if stuck:
            bits = ", ".join(f"D{i}" for i in range(8) if stuck >> i & 1)
            print(f"    ** data lines not reaching the PHY: {bits} **")
        print(
            f"    product id byte {d['pid']:#04x} "
            f"({'USB3300' if d['pid'] == 0x07 else 'unexpected'})"
        )
        print(
            f"    func_ctrl {d['func']:#04x} (want 0x45)  "
            f"otg_ctrl {d['otg']:#04x} (want 0x00)  "
            f"line {d['line_now']}  vbus {d['vbus_now']}"
        )
        # CLK is on a dedicated clock input, which has no pull-up, so its
        # level says what is on the wire but not whether anything drives it.
        names = [f"D{i}" for i in range(8)] + ["CLK", "DIR", "NXT"]
        lvl = " ".join(
            f"{n}={(d['pin_level'] >> i) & 1}{'~' if (d['pin_tog'] >> i) & 1 else ' '}"
            for i, n in enumerate(names)
        )
        print(f"    pins {lvl}   (~ = changed during the window)")
        ok = d["read_a5"] == 0xA5 and d["read_5a"] == 0x5A
        verdict = ("FPGA side OK, bus free" if ok
                   else "FAIL (bank unpowered or bus held low)")
        print(
            f"    bus drive test: 0xa5 -> {d['read_a5']:#04x}, "
            f"0x5a -> {d['read_5a']:#04x}  {verdict}"
        )

    if not d["clock_seen"]:
        # Everything below lives in the ULPI clock domain, so with no clock
        # from the PHY these are reset values, not measurements.
        print("    usb: nothing to report, the ULPI domain has never clocked")
        return

    states = ["census A5", "census A5 meas", "census 5A", "census 5A meas",
              "trying", "measuring", "locked", "detaching"]
    print(f"    search state: {states[d['srch']]}, "
          f"{d['idle_win']} windows locked but unconfigured")

    usb = []
    usb.append("PHY set up" if d["phy_ready"] else "PHY not set up")
    usb.append(f"line {d['linestate']}")
    if d["reset_seen"]:
        usb.append("bus reset seen")
    usb.append(f"addr {d['dev_addr']}")
    if d["configured"]:
        usb.append("configured")
    if d["streaming"]:
        usb.append("streaming")
    if d["playing"]:
        usb.append("playing")
    print("    usb: " + ", ".join(usb))
    # 100 start-of-frames per 100 ms window is a host talking to us at all.
    print(
        # Counters cover the interval between status frames, which is the
        # 200 ms gap plus however long the last frame took to send.  What
        # matters is that audio packets track SOFs one for one while playing.
        f"    frame {d['frame_no']:4d}  SOF {d['sof_per_frame']:4d}  "
        f"audio pkts {d['pkt_per_frame']:4d} (per trace interval)  "
        f"drops {d['drops']}  fifo over {d['over']} under {d['under']}\n"
        f"    setups accepted {d['setups']}  packets sent {d['txs']}"
    )
    # The feedback rate is 10.14 samples per USB frame; 48.000 is 0x0C0000.
    print(f"    feedback rate {d['fb'] / 16384:.4f} samples/frame "
          f"({d['fb'] * 1000 / 16384:.1f} Hz)")


def show_capture(blk):
    """Render the ULPI bus capture.  Each entry is a bus state and how long it
    lasted, so a full-speed packet reads as a short list rather than hundreds
    of identical cycles."""
    entries = []
    for i in range(CAP_SAMPLES):
        o = 2 + 4 * i
        d, c = blk[o], blk[o + 1]
        dwell = blk[o + 2] | (blk[o + 3] << 8)
        entries.append((d, c, dwell))
    if not any(dw for _, _, dw in entries):
        print("    capture: empty (never triggered)")
        return
    print("    capture:  bus  DIR NXT STP  driver  cycles")
    t = 0
    shown = 0
    for d, c, dwell in entries:
        if dwell == 0:
            break
        dirb, nxtb, stpb, oe = c & 1, (c >> 1) & 1, (c >> 2) & 1, (c >> 3) & 1
        who = "link" if oe else ("PHY " if dirb else "-   ")
        note = ""
        if dirb and nxtb:
            note = f"   <- rx {PIDS.get(d & 0x0f, '') if (d >> 4) == (~d & 0x0f) else ''}"
        elif dirb and not nxtb:
            note = "   <- rxcmd"
        print(
            f"      {t:7d}  {d:#04x}   {dirb}   {nxtb}   {stpb}   {who}  {dwell:5d}{note}"
        )
        t += dwell
        shown += 1
        if shown > 200:
            print("      ... truncated")
            break


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=1000000)
    ap.add_argument("--count", type=int, default=3)
    ap.add_argument("--follow", action="store_true", help="run until stopped")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--capture", "-c", action="store_true",
                    help="also decode the ULPI bus capture block")
    ap.add_argument("--timeout", type=float, default=5.0)
    a = ap.parse_args()

    with serial.Serial(a.port, a.baud, timeout=0.2) as ser:
        buf = bytearray()
        deadline = time.time() + a.timeout
        shown = 0
        while a.follow or shown < a.count:
            if time.time() > deadline:
                print(
                    f"no frame in {a.timeout:.0f}s "
                    f"({len(buf)} raw bytes: {bytes(buf[:32]).hex()})",
                    file=sys.stderr,
                )
                return 1
            buf += ser.read(4096)
            while True:
                i = buf.find(MAGIC)
                need = FRAME + (CAP_BYTES if a.capture else 0)
                if i < 0 or len(buf) - i < need:
                    break
                show(decode(buf[i : i + FRAME]), a.verbose)
                if a.capture:
                    blk = buf[i + FRAME : i + FRAME + CAP_BYTES]
                    if bytes(blk[:2]) == CAP_MAGIC:
                        show_capture(blk)
                    else:
                        print("    capture: block not where expected")
                del buf[: i + need]
                shown += 1
                deadline = time.time() + a.timeout
                if not a.follow and shown >= a.count:
                    break
    return 0


if __name__ == "__main__":
    sys.exit(main())
