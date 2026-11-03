#!/usr/bin/env python3
"""Turn simulation dumps into PNG pictures (no external libraries needed).

  frame2png.py frame frame.txt out.png   # 640x480 VGA frame from tb_vga +dump ("r g b" per line)
"""
import sys, zlib, struct

mode, src, dst = sys.argv[1:4]
if mode == "frame":
    W, H = 640, 480
    px = [tuple(int(v) * 17 for v in l.split()) for l in open(src)]
else:
    W, H = 640, 480
    pix = []
    for l in open(src):
        v = int(l.strip(), 16)
        pix.append((((v >> 8) & 15) * 17, ((v >> 4) & 15) * 17, (v & 15) * 17))
    px = [pix[(y // 4) * 160 + (x // 4)] for y in range(H) for x in range(W)]
assert len(px) == W * H, f"expected {W*H} pixels, got {len(px)}"

raw = b"".join(b"\x00" + bytes(c for p in px[y * W:(y + 1) * W] for c in p) for y in range(H))
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
open(dst, "wb").write(png)
print("wrote", dst)
