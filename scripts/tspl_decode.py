"""Decode a captured TSPL byte stream (from pklg_extract.py --out) back into commands and an image.

Handles BITMAP mode 3 as observed from Pixmate:
  BITMAP x,y,width_bytes,height,3,<compressed_len>,<zlib data>
and the plain modes 0-2 (raw width_bytes*height bytes).

Usage: .venv/bin/python scripts/tspl_decode.py tests/golden/pixmate-capture-a.bin [--png out.png]
"""

import argparse
import re
import sys
import zlib
from pathlib import Path

from PIL import Image

DOTS_PER_MM = 8  # 203 dpi


def parse(stream: bytes):
    """Yield ("cmd", text) / ("bitmap", dict) / ("raw", bytes) items in order."""
    i = 0
    while i < len(stream):
        if stream.startswith(b"BITMAP ", i):
            # Header: 5 or 6 comma-separated numbers, then the data.
            m = re.compile(rb"BITMAP (\d+),(\d+),(\d+),(\d+),(\d+),").match(stream, i)
            if not m:
                raise ValueError(f"bad BITMAP header at {i}")
            x, y, wb, h, mode = map(int, m.groups())
            j = m.end()
            if mode == 3:
                m2 = re.compile(rb"(\d+),").match(stream, j)
                clen = int(m2.group(1))
                j = m2.end()
                comp = stream[j: j + clen]
                data = zlib.decompress(comp)
                j += clen
            else:
                clen = None
                data = stream[j: j + wb * h]
                j += wb * h
            if len(data) != wb * h:
                raise ValueError(f"BITMAP at {i}: got {len(data)} bytes, expected {wb * h}")
            yield "bitmap", {"x": x, "y": y, "wb": wb, "h": h, "mode": mode,
                             "clen": clen, "data": data}
            # Some encoders terminate BITMAP data with CRLF; skip it if present.
            if stream.startswith(b"\r\n", j):
                j += 2
            i = j
        elif stream[i] == 0x1B:  # ESC sequence, e.g. <ESC>!? status query
            yield "raw", stream[i: i + 3]
            i += 3
        else:
            end = stream.find(b"\r\n", i)
            if end < 0:
                yield "raw", stream[i:]
                break
            yield "cmd", stream[i:end].decode("ascii", "replace")
            i = end + 2


def render(items, width_dots: int, height_dots: int) -> Image.Image:
    """Compose BITMAP bands onto a canvas.

    Observed on the Y813 (mode 3): bit 1 = black dot, 0 = white, MSB = leftmost dot.
    Blank label areas arrive as all-zero bytes. This is inverted from classic TSPL.
    """
    img = Image.new("1", (width_dots, height_dots), 1)
    for kind, v in items:
        if kind != "bitmap":
            continue
        # PIL mode "1" treats bit 1 as white, so invert to get 1 = black.
        band = Image.frombytes("1", (v["wb"] * 8, v["h"]), bytes(b ^ 0xFF for b in v["data"]))
        img.paste(band, (v["x"], v["y"]))
    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stream", type=Path)
    ap.add_argument("--png", type=Path)
    args = ap.parse_args()

    items = list(parse(args.stream.read_bytes()))
    size = (0, 0)
    for kind, v in items:
        if kind == "cmd":
            print(" ", v)
            m = re.match(r"SIZE ([\d.]+) mm,\s*([\d.]+) mm", v)
            if m:
                size = (round(float(m.group(1)) * DOTS_PER_MM), round(float(m.group(2)) * DOTS_PER_MM))
        elif kind == "bitmap":
            black = sum(bin(b).count("1") for b in v["data"]) / (len(v["data"]) * 8)
            print(f"  BITMAP x={v['x']} y={v['y']} {v['wb']}B({v['wb'] * 8}px) x {v['h']} "
                  f"mode={v['mode']} comp={v['clen']} raw={len(v['data'])} black={black:.1%}")
        else:
            print("  RAW", v.hex(" "))
    if args.png:
        render(items, *size).save(args.png)
        print("wrote", args.png, size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
