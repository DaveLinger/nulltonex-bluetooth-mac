"""The Swift print service must match the Python reference.

Build first: macos/build.sh. Skipped if the app binary is missing.
Run: .venv/bin/python -m unittest discover -s tests
"""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import tspl_decode  # noqa: E402
from test_raster import make_pdf  # noqa: E402
from y813 import raster  # noqa: E402

BIN = ROOT / "macos" / "build" / "Y813PrintService.app" / "Contents" / "MacOS" / "Y813PrintService"
GOLDEN = ROOT / "tests" / "golden"
VOID = ROOT / "fixtures" / "pirateship-ups-void-4x6.pdf"  # not redistributed; see README


@unittest.skipUnless(BIN.exists(), "Swift app not built (macos/build.sh)")
class SwiftPortTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def swift(self, *args) -> str:
        return subprocess.run([str(BIN), *map(str, args)], check=True, capture_output=True,
                              text=True, timeout=60).stdout

    def test_encoder_matches_pixmate_bytes(self):
        jobs = sorted(GOLDEN.glob("pixmate-*.bin"))
        self.assertEqual(len(jobs), 5)
        for path in jobs:
            with self.subTest(job=path.name):
                captured = path.read_bytes()
                items = list(tspl_decode.parse(captured))
                cmds = [v for k, v in items if k == "cmd"]
                density = next(c for c in cmds if c.startswith("DENSITY")).split()[1]
                w, h = map(int, re.match(r"SIZE (\d+) mm,(\d+) mm",
                                         next(c for c in cmds if c.startswith("SIZE"))).groups())
                pbm = self.tmp / f"{path.stem}.pbm"
                tspl_decode.render(items, w * 8, h * 8).save(pbm, format="PPM")
                out = self.tmp / f"{path.stem}.bin"
                self.swift("encode", pbm, out, "--width-mm", w, "--height-mm", h, "--density", density)
                self.assertEqual(out.read_bytes(), captured)

    def check_render(self, pdf: Path, fit: str = "auto"):
        py = raster.pdf_to_label(pdf, fit=fit)
        pbm = self.tmp / (pdf.stem + ".pbm")
        info = self.swift("render", pdf, pbm, "--fit", fit)
        scale = float(re.search(r"scale=([\d.]+)", info).group(1))
        rotated = re.search(r"rotated=(\d)", info).group(1) == "1"
        sw = Image.open(pbm).convert("1")
        self.assertEqual(sw.size, py.image.size)
        self.assertAlmostEqual(scale, py.scale, places=3)
        self.assertEqual(rotated, py.rotated)
        # CoreGraphics and pdfium differ on anti-aliased edges, and pdfium rounds a 1218.99-row
        # page up to 1220 rows, stretching embedded bitmaps by one row (CoreGraphics maps them 1:1).
        # So compare at the best +-1 dot offset and allow edge-row differences on thin-line pages.
        a, b = sw.convert("L"), py.image.convert("L")
        changed = min(sum(1 for p, q in zip(ImageChops.offset(a, dx, dy).tobytes(), b.tobytes()) if p != q)
                      for dx in (-1, 0, 1) for dy in (-1, 0, 1))
        ink = sum(1 for v in b.tobytes() if v == 0)
        self.assertLess(changed, 0.15 * ink + 200, f"{pdf.name}: {changed} px differ, ink {ink}")
        return info

    @unittest.skipUnless(VOID.exists(), "optional Pirate Ship sample label not present")
    def test_render_void_label_matches(self):
        info = self.check_render(VOID)
        self.assertIn("clip=0,0,0,0", info)

    def test_render_scan_test_matches(self):
        self.check_render(ROOT / "fixtures" / "scan-test-4x6.pdf")

    def test_render_margins_and_landscape(self):
        self.check_render(make_pdf(self.tmp / "m.pdf", 4, 6, inset_mm=4))
        self.check_render(make_pdf(self.tmp / "l.pdf", 6, 4, inset_mm=4))

    def test_render_rejects_letter(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.swift("render", make_pdf(self.tmp / "letter.pdf", 8.5, 11), self.tmp / "x.pbm")


if __name__ == "__main__":
    unittest.main()
