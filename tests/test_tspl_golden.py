"""Golden tests: re-encode the images Pixmate sent and compare byte for byte.

tests/golden/pixmate-*.bin are the exact byte streams Pixmate 1.0.6 wrote to the printer
(test images only), and pixmate-writes.json holds the observed BLE write sizes.
"""

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))

import tspl_decode  # noqa: E402
from y813 import ble, tspl  # noqa: E402

GOLDEN = ROOT / "tests" / "golden"


def golden_jobs():
    return sorted(GOLDEN.glob("pixmate-*.bin"))


def job_params(captured: bytes):
    items = list(tspl_decode.parse(captured))
    cmds = [v for k, v in items if k == "cmd"]
    density = int(next(c for c in cmds if c.startswith("DENSITY")).split()[1])
    w, h = map(int, re.match(r"SIZE (\d+) mm,(\d+) mm", next(c for c in cmds if c.startswith("SIZE"))).groups())
    return items, density, w, h


class GoldenTests(unittest.TestCase):
    def test_golden_files_present(self):
        self.assertEqual(len(golden_jobs()), 5)

    def test_reencode_matches_pixmate(self):
        for path in golden_jobs():
            with self.subTest(job=path.name):
                captured = path.read_bytes()
                items, density, w, h = job_params(captured)
                img = tspl_decode.render(items, w * tspl.DOTS_PER_MM, h * tspl.DOTS_PER_MM)
                self.assertEqual(tspl.encode_job(img, width_mm=w, height_mm=h, density=density), captured)

    def test_write_plan_matches_pixmate(self):
        observed = json.loads((GOLDEN / "pixmate-writes.json").read_text())["jobs"]
        for name, info in observed.items():
            with self.subTest(job=name):
                job = (GOLDEN / f"pixmate-{name}.bin").read_bytes()
                self.assertEqual([len(w) for w in ble.plan_writes(job)], info["write_sizes"])

    def test_rejects_oversize(self):
        from PIL import Image
        with self.assertRaises(ValueError):
            tspl.encode_job(Image.new("1", (800, 100), 1), width_mm=98, height_mm=150)


if __name__ == "__main__":
    unittest.main()
