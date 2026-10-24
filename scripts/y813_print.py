"""Print a 4x6 label PDF on the Y813: PDF -> 1-bit raster -> TSPL job -> BLE.

  .venv/bin/python scripts/y813_print.py label.pdf [--fit auto|crop|shrink] [--density 11]
      [--out jobs/next.bin] [--preview preview.png] [--send]

Without --send it only builds the job file (send it with scripts/send_job.command).
--send must run from Terminal.app (Bluetooth permission).
"""

import argparse
import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from y813 import ble, raster, tspl  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf", type=Path)
    ap.add_argument("--page", type=int, default=1)
    ap.add_argument("--fit", choices=("auto", "crop", "shrink"), default="auto")
    ap.add_argument("--density", type=int, default=11, help="0-15; Pixmate Medium=11, Dark=14")
    ap.add_argument("--out", type=Path, default=ROOT / "jobs" / "next.bin")
    ap.add_argument("--preview", type=Path)
    ap.add_argument("--send", action="store_true")
    args = ap.parse_args()

    try:
        r = raster.pdf_to_label(args.pdf, fit=args.fit, page_index=args.page - 1)
    except raster.PageSizeError as e:
        print(f"error: {e}")
        return 2
    w_in, h_in = r.page_size_pt[0] / 72, r.page_size_pt[1] / 72
    print(f"page {w_in:.2f}x{h_in:.2f} in{' (rotated)' if r.rotated else ''} -> "
          f"{r.image.width}x{r.image.height} dots, scale {r.scale * 100:.1f} %")
    c = r.clip
    if c.total or c.rule_lines_dropped:
        print(f"  cut off: content dots L{c.left} R{c.right} T{c.top} B{c.bottom}; "
              f"frame/rule lines {len(c.rule_lines_dropped)}")
    if args.preview:
        r.image.save(args.preview)
        print(f"  preview: {args.preview}")

    job = tspl.encode_job(r.image, width_mm=raster.LABEL_W_MM, height_mm=raster.LABEL_H_MM,
                          density=args.density)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(job)
    print(f"  job: {args.out} ({len(job)} bytes, DENSITY {args.density})")

    if args.send:
        status = asyncio.run(ble.send_job(job))
        return 0 if status == 0 else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
