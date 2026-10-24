"""Generate deterministic test fixtures for the Y813.

fixtures/calibration-4x6.{png,pdf}  4x6 in at 203 DPI: 1 mm border inset, 10 mm grid,
                                    mm ruler ticks, fine text, a Code128 sample that isn't live.
fixtures/capture-a.png / capture-b.png  Tiny 40x30 mm variants for diffing BLE captures
                                    (a: blank with a 2 mm black bar on top; b: same + checker block).

DPI is assumed to be 203 until measured; re-run with --dpi if that changes.
"""

import argparse
from pathlib import Path

import barcode
from barcode.writer import ImageWriter
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "fixtures"


def mm(v: float, dpi: int) -> int:
    return round(v * dpi / 25.4)


def font(size: int) -> ImageFont.ImageFont:
    for path in ("/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def calibration(dpi: int) -> Image.Image:
    w, h = round(4 * dpi), round(6 * dpi)
    img = Image.new("1", (w, h), 1)
    d = ImageDraw.Draw(img)

    inset = mm(1, dpi)
    d.rectangle([inset, inset, w - 1 - inset, h - 1 - inset], outline=0, width=2)

    for x_mm in range(10, 102, 10):
        x = mm(x_mm, dpi)
        d.line([x, inset, x, h - 1 - inset], fill=0, width=1)
    for y_mm in range(10, 153, 10):
        y = mm(y_mm, dpi)
        d.line([inset, y, w - 1 - inset, y], fill=0, width=1)

    # mm ticks along top and left edges, longer every 5 mm.
    for i in range(0, 102):
        x = mm(i, dpi)
        d.line([x, inset, x, inset + (mm(4, dpi) if i % 5 == 0 else mm(2, dpi))], fill=0)
    for i in range(0, 153):
        y = mm(i, dpi)
        d.line([inset, y, inset + (mm(4, dpi) if i % 5 == 0 else mm(2, dpi)), y], fill=0)

    big, small, tiny = font(mm(5, dpi)), font(mm(2.5, dpi)), font(mm(1.5, dpi))
    d.text((mm(12, dpi), mm(12, dpi)), "Y813 CALIBRATION 4x6", font=big, fill=0)
    d.text((mm(12, dpi), mm(20, dpi)), f"{w}x{h} px @ {dpi} dpi  - NOT A SHIPPING LABEL",
           font=small, fill=0)
    d.text((mm(12, dpi), mm(25, dpi)), "TOP edge (feed direction marker) ^", font=small, fill=0)
    for i, size in enumerate((3, 2.5, 2, 1.5, 1.2)):
        d.text((mm(12, dpi), mm(32 + i * 4, dpi)),
               f"{size} mm text: The quick brown fox 0123456789", font=font(mm(size, dpi)), fill=0)
    d.text((mm(12, dpi), mm(140, dpi)), "BOTTOM edge", font=small, fill=0)
    d.text((w - mm(30, dpi), h - mm(6, dpi)), "1.5mm corner", font=tiny, fill=0)

    # 1-px checker patch for dot-accuracy and darkness inspection.
    px, py, size = mm(62, dpi), mm(52, dpi), mm(20, dpi)
    for yy in range(size):
        for xx in range(size):
            if (xx + yy) % 2 == 0:
                img.putpixel((px + xx, py + yy), 0)

    code = barcode.get("code128", "SAMPLE-0000-NOTLIVE", writer=ImageWriter())
    bc = code.render(writer_options={"module_width": 0.375, "module_height": 18,
                                     "quiet_zone": 4, "font_size": 8, "text_distance": 3,
                                     "dpi": dpi, "write_text": True}).convert("1")
    img.paste(bc, ((w - bc.width) // 2, mm(80, dpi)))
    # Redraw the border so the barcode's quiet zone can't hide edge clipping.
    d.rectangle([inset, inset, w - 1 - inset, h - 1 - inset], outline=0, width=2)
    return img


def capture_variant(dpi: int, checker: bool) -> Image.Image:
    w, h = mm(40, dpi), mm(30, dpi)
    img = Image.new("1", (w, h), 1)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w - 1, mm(2, dpi)], fill=0)
    if checker:
        x0, y0, s = mm(5, dpi), mm(8, dpi), 8
        for r in range(4):
            for c in range(4):
                if (r + c) % 2 == 0:
                    d.rectangle([x0 + c * s, y0 + r * s, x0 + (c + 1) * s - 1, y0 + (r + 1) * s - 1],
                                fill=0)
    return img


def width_probe(width_mm: int = 104, height_mm: int = 150) -> Image.Image:
    """Ruler label at exact printer dots (8/mm) to measure the physically printable area.

    Full-width black bars and 1 mm ticks across the whole canvas; marks at 98 mm
    (Pixmate's width) and 101.6 mm (4 in). Wherever the print stops is the head/label limit.
    """
    d8 = 8
    w, h = width_mm * d8, height_mm * d8
    img = Image.new("1", (w, h), 1)
    d = ImageDraw.Draw(img)
    num, small = font(28), font(22)

    def ruler(y: int) -> None:
        d.rectangle([0, y, w - 1, y + 23], fill=0)                      # 3 mm solid bar
        for i in range(width_mm + 1):
            x = min(i * d8, w - 1)
            d.line([x, y + 24, x, y + 24 + (40 if i % 10 == 0 else 24 if i % 5 == 0 else 12)],
                   fill=0, width=2 if i % 10 == 0 else 1)
            if i % 10 == 0 and 0 < i < width_mm:
                d.text((x - 14, y + 68), str(i), font=num, fill=0)

    for y in (8, 560, 1100):
        ruler(y)
    # Too little room between the two lines for labels; name both left of the 98 mm line.
    d.line([98 * d8, 120, 98 * d8, 540], fill=0, width=1)
    d.line([round(101.6 * d8), 120, round(101.6 * d8), 540], fill=0, width=1)
    d.text((98 * d8 - 150, 130), "line 1: 98mm", font=small, fill=0)
    d.text((98 * d8 - 150, 170), "line 2: 4 in", font=small, fill=0)
    d.rectangle([0, 0, 1, h - 1], fill=0)                                # dot columns 0-1
    d.rectangle([w - 2, 0, w - 1, h - 1], fill=0)                        # last two dot columns
    for i in range(0, height_mm + 1):                                    # left-edge length ruler
        y = min(i * d8, h - 1)
        d.line([0, y, 16 if i % 10 == 0 else 8, y], fill=0)
    d.text((120, 260), f"WIDTH PROBE  SIZE {width_mm} mm,{height_mm} mm", font=num, fill=0)
    d.text((120, 300), f"canvas {w}x{h} dots @ 8 dots/mm", font=small, fill=0)
    d.text((120, 340), "Read where the bars stop vs. the ruler numbers", font=small, fill=0)
    return img


SCAN_TEST_CODES = [
    # (label, data, module dots, rotate)
    ("Code128 1Z test no., 3-dot (15 mil) modules", "1Z999AA10123456784", 3, False),
    ("Code128 same, 2-dot (10 mil) modules", "1Z999AA10123456784", 2, False),
    ("Code128 420+ZIP, 3-dot modules", "42029483", 3, False),
    ("Code128 420+ZIP rotated 90 (ladder), 3-dot modules", "42029483", 3, True),
]


def scan_test() -> Image.Image:
    """True 4x6 page at exactly 8 dots/mm with >= 6 mm margins, so it prints at 100 %
    with no resampling. Holds decodable Code128 barcodes in both bar orientations.
    1Z999AA10123456784 is UPS's published documentation example, not a live label.
    """
    d8 = 8
    w, h = round(101.6 * d8), round(152.4 * d8)  # 813 x 1219
    img = Image.new("1", (w, h), 1)
    d = ImageDraw.Draw(img)
    m = 6 * d8
    d.text((m, m), "Y813 SCAN TEST - NOT A SHIPPING LABEL", font=font(30), fill=0)
    y = m + 50
    for label, data, mod, rotate in SCAN_TEST_CODES:
        # Draw modules at exact whole-dot widths. python-barcode's ImageWriter positions
        # bars in rounded mm, which turns 2-dot modules into 2/3/5/7-dot bars.
        pattern = barcode.get("code128", data).build()[0]
        quiet = 10 * mod
        bh = 12 * d8 if not rotate else 10 * d8
        bc = Image.new("1", (len(pattern) * mod + 2 * quiet, bh + 28), 1)
        bd = ImageDraw.Draw(bc)
        for i, bit in enumerate(pattern):
            if bit == "1":
                x = quiet + i * mod
                bd.rectangle([x, 0, x + mod - 1, bh - 1], fill=0)
        bd.text((bc.width // 2, bh + 2), data, font=font(20), fill=0, anchor="ma")
        if rotate:
            bc = bc.rotate(90, expand=True)
        d.text((m, y), label, font=font(20), fill=0)
        img.paste(bc, ((w - bc.width) // 2, y + 26))
        y += 26 + bc.height + 16
    if y > h - m:
        raise ValueError(f"scan test overflows page: {y} > {h - m}")
    return img


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dpi", type=int, default=203)
    args = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    cal = calibration(args.dpi)
    cal.save(OUT / "calibration-4x6.png", dpi=(args.dpi, args.dpi))
    cal.save(OUT / "calibration-4x6.pdf", resolution=args.dpi)
    capture_variant(args.dpi, False).save(OUT / "capture-a.png", dpi=(args.dpi, args.dpi))
    capture_variant(args.dpi, True).save(OUT / "capture-b.png", dpi=(args.dpi, args.dpi))
    width_probe().save(OUT / "width-probe-104x150.png", dpi=(203, 203))
    scan_test().save(OUT / "scan-test-4x6.pdf", resolution=203.2)
    print("wrote", sorted(p.name for p in OUT.iterdir()))


if __name__ == "__main__":
    main()
