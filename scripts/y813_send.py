"""Send a print job to the Y813 over BLE.

  --replay FILE   send a captured job byte-for-byte (e.g. tests/golden/pixmate-capture-a.bin)
  --dry-run       show the write plan and decoded commands without connecting

Run from Terminal.app (Bluetooth permission). Example:
  .venv/bin/python scripts/y813_send.py --replay tests/golden/pixmate-capture-a.bin
"""

import argparse
import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))

import tspl_decode  # noqa: E402
from y813 import ble  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--replay", type=Path, required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--name", default="Y813")
    args = ap.parse_args()

    job = args.replay.read_bytes()
    # Refuse anything that doesn't decode as a TSPL job ending in PRINT.
    items = list(tspl_decode.parse(job))
    cmds = [v for k, v in items if k == "cmd"]
    if not any(c.startswith("PRINT") for c in cmds):
        print("refusing: job has no PRINT command")
        return 2
    for c in cmds:
        print(" ", c)
    print(f"  ({sum(k == 'bitmap' for k, _ in items)} BITMAP bands)")

    writes = ble.plan_writes(job)
    print(f"{len(job)} bytes -> {len(writes)} writes: sizes {[len(w) for w in writes[:3]]}..."
          f"{len(writes[-1])}, first={writes[0]!r}")
    if args.dry_run:
        return 0
    status = asyncio.run(ble.send_job(job, name_prefix=args.name))
    return 0 if status == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
