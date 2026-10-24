"""PDF -> label raster tests. Run: .venv/bin/python -m unittest discover -s tests"""

import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from y813 import raster  # noqa: E402

# Pirate Ship's VOID sample label (free download from Pirate Ship; not redistributed here).
VOID = ROOT / "fixtures" / "pirateship-ups-void-4x6.pdf"
needs_void = unittest.skipUnless(VOID.exists(), "optional Pirate Ship sample label not present")


def make_pdf(path: Path, w_in: float, h_in: float, inset_mm: float = 5) -> Path:
    """4x6-ish test page: a 3-dot box inset `inset_mm` from the edges, plus a center bar."""
    dpi = 203.2
    w, h = round(w_in * dpi), round(h_in * dpi)
    img = Image.new("1", (w, h), 1)
    d = ImageDraw.Draw(img)
    i = round(inset_mm * dpi / 25.4)
    d.rectangle([i, i, w - 1 - i, h - 1 - i], outline=0, width=3)
    d.rectangle([w // 2 - 40, h // 2 - 4, w // 2 + 40, h // 2 + 4], fill=0)
    img.save(path, resolution=dpi)
    return path


class RasterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    @needs_void
    def test_void_label_auto_shrinks_to_fit(self):
        r = raster.pdf_to_label(VOID)
        self.assertEqual(r.image.size, (800, 1200))
        self.assertAlmostEqual(r.scale, 0.984, places=3)
        self.assertEqual(r.clip.total, 0)

    @needs_void
    def test_void_label_crop_reports_cut_text(self):
        r = raster.pdf_to_label(VOID, fit="crop")
        self.assertEqual(r.scale, 1.0)
        self.assertGreater(r.clip.top, 0)       # tops of the sender-address letters
        self.assertGreater(r.clip.bottom, 0)    # footer line
        self.assertTrue(r.clip.rule_lines_dropped)  # the 2-dot page frame

    def test_page_with_margins_prints_at_100_percent(self):
        r = raster.pdf_to_label(make_pdf(self.tmp / "m.pdf", 4, 6, inset_mm=4))
        self.assertEqual(r.scale, 1.0)
        self.assertEqual(r.clip.total, 0)
        # Box inset 4 mm on a 101.6 mm page lands ~(4 - 0.8) mm = ~26 dots inside the label.
        bbox = Image.eval(r.image.convert("L"), lambda v: 255 - v).getbbox()
        self.assertTrue(20 <= bbox[0] <= 32, bbox)
        self.assertTrue(20 <= 800 - bbox[2] <= 32, bbox)

    def test_landscape_is_rotated_to_portrait(self):
        r = raster.pdf_to_label(make_pdf(self.tmp / "l.pdf", 6, 4, inset_mm=4))
        self.assertTrue(r.rotated)
        self.assertEqual(r.image.size, (800, 1200))

    def test_letter_page_rejected(self):
        with self.assertRaises(raster.PageSizeError):
            raster.pdf_to_label(make_pdf(self.tmp / "letter.pdf", 8.5, 11))

    def test_never_stretches(self):
        r = raster.pdf_to_label(make_pdf(self.tmp / "s.pdf", 4, 6, inset_mm=0.2), fit="shrink")
        # Uniform scale: the box keeps the page's 4:6 aspect within a dot or two.
        bbox = Image.eval(r.image.convert("L"), lambda v: 255 - v).getbbox()
        w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
        self.assertAlmostEqual(w / h, (101.6 - 0.4) / (152.4 - 0.4), delta=0.004)


if __name__ == "__main__":
    unittest.main()
