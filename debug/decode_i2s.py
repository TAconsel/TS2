"""Decode i2s_monitor probe reads captured by debug/read_i2s.tcl.

    quartus_stp_tcl -t debug/read_i2s.tcl > /tmp/p.txt
    python3 debug/decode_i2s.py /tmp/p.txt

Independently re-derives the expected sine values from the same constants the
RTL uses, so a mismatch between design intent and the actual bus shows up as a
failed column rather than having to be eyeballed.  Probe layout must stay in
step with i2s_monitor.vhd.
"""
import math
import re
import sys
from fractions import Fraction

# Must match audio_pll / i2s_master / tone_gen.
FS = Fraction(50_000_000 * 173, 176 * 128)    # 383966.6193 Hz
INC, PB = 43694, 24
N, AMP, ATTEN = 256, 32767, 1

TABLE = [int(round(AMP * math.sin(2 * math.pi * i / N))) for i in range(N)]
EXPECT = [((TABLE[i] >> ATTEN) << 8) & 0xFFFFFF for i in range(N)]
FS_OK = {int(FS), int(FS) + 1}                 # +-1 count of gate quantisation
TONE_HZ = INC * float(FS) / 2 ** PB


def s24(u):
    return u - (1 << 24) if u & (1 << 23) else u


print("%-3s %-5s %-8s %-8s %-11s %-11s %-6s %-6s %s" %
      ("#", "lock", "Fs(Hz)", "tone(Hz)", "left", "right", "L==R", "onLUT",
       "framing"))
ok, rows = True, 0
for line in open(sys.argv[1]):
    m = re.match(r"PROBE (\d+): ([01]+)", line.strip())
    if not m:
        continue
    i, b = m.group(1), m.group(2)
    assert len(b) == 119, "probe width %d, expected 119" % len(b)
    lock, snap, ref = b[0], b[1:65], b[65:89]
    fs, tone = int(b[89:108], 2), int(b[108:], 2)

    lh, rh = snap[:32], snap[32:]
    lu, ru = int(lh[1:25], 2), int(rh[1:25], 2)
    lval, rval = s24(lu), s24(ru)
    framing = (lh[0] == '0' and rh[0] == '0'
               and set(lh[25:]) == {'0'} and set(rh[25:]) == {'0'})
    onlut = lu in EXPECT and int(ref, 2) in EXPECT

    print("%-3s %-5s %-8d %-8d %-11d %-11d %-6s %-6s %s" %
          (i, lock, fs, tone, lval, rval, lval == rval, onlut,
           "clean" if framing else "BAD"))
    rows += 1
    if not (lock == '1' and fs in FS_OK and tone in (999, 1000, 1001)
            and lval == rval and framing and onlut):
        ok = False

print()
print("expected  Fs = %.4f Hz (%+.0f ppm vs 384000) -> counts as %s"
      % (FS, (float(FS) - 384000) / 384000 * 1e6, sorted(FS_OK)))
print("expected tone = %.4f Hz -> counts as 1000" % TONE_HZ)
print("reads: %d   all consistent: %s" % (rows, ok))
