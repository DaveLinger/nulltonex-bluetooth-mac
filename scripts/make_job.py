"""Build a Y813 TSPL job file from a 1-bit image that is already at printer dots (8/mm).

No scaling: the image must fit inside SIZE width x height. Send the result with
scripts/y813_send.py --replay <job.bin>.

  .venv/bin/python scripts/make_job.py fixtures/width-probe-104x150.png \
      --width-mm 104 --height-mm 150 --out jobs/width-probe.bin
"""

import argparse
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from y813 import tspl  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("image", type=Path)
    ap.add_argument("--width-mm", type=int, required=True)
    ap.add_argument("--height-mm", type=int, required=True)
    ap.add_argument("--density", type=int, default=11)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    img = Image.open(args.image)
    if img.mode != "1":
        img = img.convert("L").point(lambda v: 255 if v >= 128 else 0, "1")
    job = tspl.encode_job(img, width_mm=args.width_mm, height_mm=args.height_mm,
                          density=args.density)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(job)
    print(f"wrote {args.out}: {img.width}x{img.height} dots, {len(job)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
