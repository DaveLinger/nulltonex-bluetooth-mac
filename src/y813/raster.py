"""PDF -> 1-bit label raster for the Y813 (see docs/pdf-mapping.md).

Renders vector content directly at the printer's 8 dots/mm grid (no bitmap resampling),
thresholds, and centers the page on the label. The printer centers the SIZE canvas on
the media, so the canvas is the label itself (100 x 150 mm = 800 x 1200 dots).
"""

from dataclasses import dataclass, field
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image

DOTS_PER_MM = 8
PT_PER_MM = 72 / 25.4
THRESHOLD = 128  # anti-aliased edges split at 50 % keep bar widths accurate

# Physical media measured 2026-10-24 (width probe + G0 print).
LABEL_W_MM = 100
LABEL_H_MM = 150

# Page sizes we accept (portrait, in points): true 4x6 and the 100x150 mm label itself.
ACCEPTED_PAGES_PT = [(288.0, 432.0), (LABEL_W_MM * PT_PER_MM, LABEL_H_MM * PT_PER_MM)]
PAGE_TOLERANCE = 0.02


class PageSizeError(ValueError):
    pass


@dataclass
class ClipReport:
    """Ink (black dots) that falls outside the label, excluding page-length rule lines."""
    left: int = 0
    right: int = 0
    top: int = 0
    bottom: int = 0
    rule_lines_dropped: list[str] = field(default_factory=list)

    @property
    def total(self) -> int:
        return self.left + self.right + self.top + self.bottom


@dataclass
class RasterResult:
    image: Image.Image          # mode "1", exactly label size in dots
    scale: float                # 1.0 = 100 %
    rotated: bool
    clip: ClipReport
    page_size_pt: tuple[float, float]


def _check_page(w: float, h: float) -> bool:
    """Return True if the page is landscape (needs rotation). Raise if not a label page."""
    for pw, ph in ACCEPTED_PAGES_PT:
        for (a, b), rotated in (((w, h), False), ((h, w), True)):
            if abs(a - pw) / pw <= PAGE_TOLERANCE and abs(b - ph) / ph <= PAGE_TOLERANCE:
                return rotated
    raise PageSizeError(
        f"page is {w / 72:.2f} x {h / 72:.2f} in; expected a 4x6 in (or 100x150 mm) label page. "
        "Letter/A4 sheets with a label on them are not supported yet.")


def render_page(pdf_path: Path, page_index: int = 0, scale: float = 1.0
                ) -> tuple[Image.Image, bool, tuple[float, float]]:
    """Render one page to a portrait 1-bit image at 8 dots/mm x scale."""
    pdf = pdfium.PdfDocument(str(pdf_path))
    if page_index >= len(pdf):
        raise ValueError(f"PDF has {len(pdf)} page(s); page {page_index + 1} requested")
    page = pdf[page_index]
    w, h = page.get_size()  # honours /Rotate
    rotated = _check_page(w, h)
    gray = page.render(scale=DOTS_PER_MM / PT_PER_MM * scale, grayscale=True).to_pil().convert("L")
    if rotated:
        gray = gray.rotate(-90, expand=True)  # landscape -> portrait, clockwise
    bw = gray.point(lambda v: 255 if v >= THRESHOLD else 0, "1")
    return bw, rotated, (w, h)


def _clip_report(page: Image.Image, x0: int, y0: int, cw: int, ch: int) -> ClipReport:
    """Count ink outside the canvas window [x0, x0+cw) x [y0, y0+ch) in page coordinates.

    Rows/columns that are >= 90 % ink over the whole page are frame/rule lines and are
    reported separately rather than counted as content.
    """
    W, H = page.size
    px = page.load()
    black = [[px[x, y] == 0 for x in range(W)] for y in range(H)]
    rule_rows = {y for y in range(H) if sum(black[y]) >= 0.9 * W}
    rule_cols = {x for x in range(W) if sum(black[y][x] for y in range(H)) >= 0.9 * H}

    rep = ClipReport()
    for y in range(H):
        for x in range(W):
            if not black[y][x] or y in rule_rows or x in rule_cols:
                continue
            if x < x0:
                rep.left += 1
            elif x >= x0 + cw:
                rep.right += 1
            elif y < y0:
                rep.top += 1
            elif y >= y0 + ch:
                rep.bottom += 1
    for y in sorted(rule_rows):
        if y < y0 or y >= y0 + ch:
            rep.rule_lines_dropped.append(f"row {y}")
    for x in sorted(rule_cols):
        if x < x0 or x >= x0 + cw:
            rep.rule_lines_dropped.append(f"col {x}")
    return rep


def pdf_to_label(pdf_path: Path, *, fit: str = "auto", max_clip_dots: int = 50,
                 page_index: int = 0) -> RasterResult:
    """Rasterize a label PDF onto the 100 x 150 mm label.

    fit="crop":   100 % scale, centered; whatever overhangs the label is cut.
    fit="shrink": uniform scale so the whole page fits (never stretches one axis).
    fit="auto":   crop, unless more than `max_clip_dots` of non-rule ink would be cut.
    """
    if fit not in ("auto", "crop", "shrink"):
        raise ValueError("fit must be auto, crop or shrink")
    cw, ch = LABEL_W_MM * DOTS_PER_MM, LABEL_H_MM * DOTS_PER_MM

    page, rotated, size_pt = render_page(pdf_path, page_index)
    scale = 1.0
    x0, y0 = (page.width - cw) // 2, (page.height - ch) // 2
    clip = _clip_report(page, x0, y0, cw, ch) if (x0 > 0 or y0 > 0) else ClipReport()

    if fit == "shrink" or (fit == "auto" and clip.total > max_clip_dots):
        scale = min(cw / page.width, ch / page.height, 1.0)
        if scale < 1.0:
            page, rotated, size_pt = render_page(pdf_path, page_index, scale)
            x0, y0 = (page.width - cw) // 2, (page.height - ch) // 2
            clip = _clip_report(page, x0, y0, cw, ch) if (x0 > 0 or y0 > 0) else ClipReport()

    canvas = Image.new("1", (cw, ch), 1)
    canvas.paste(page, (-x0, -y0))
    return RasterResult(canvas, scale, rotated, clip, size_pt)
