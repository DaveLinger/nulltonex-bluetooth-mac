# Rendering label PDFs for the Y813

Implemented twice with the same policy: `src/y813/raster.py` (pdfium) and `macos/Sources/Raster.swift` (CoreGraphics).

## The media problem

- The Y813's common label stock is **100 × 150 mm** (800 × 1200 dots at 8 dots/mm), while carrier "4×6" PDFs are **101.6 × 152.4 mm** (813 × 1219 dots).
- The printer centers the `SIZE` canvas on the label. It was measured with a ruler probe at `SIZE 104 mm`: ~2 mm went missing on each side of the label. So the canvas is the label itself: `SIZE 100 mm,150 mm`.
- A true 4×6 page at 100 % therefore overhangs the label by ~6–7 dots per side horizontally and ~9–10 rows at the top and bottom.

Pixmate's answer is to resample every job to a 98 mm canvas (×0.9655). That prints labels 3.5 % small and smears thin lines.

## Policy

1. **Render the PDF directly at 8 dots/mm** (203.2 dpi) from its vector content. Never rescale a rendered bitmap.
2. **Threshold at 50 %, don't dither.** Barcodes and MaxiCode need hard edges, and splitting anti-aliased edges at 50 % keeps bar widths accurate. (This is Pixmate's "Text Mode".)
3. **Default to 100 % scale**, centered on the label.
4. **`fit=auto` (default):** if the crop would cut off more than 50 dots of real content, re-render at the uniform scale that fits (`min(800/W, 1200/H)`) instead. Rows or columns that are ≥ 90 % ink across the whole page count as frame or rule lines, not content, so losing a page border doesn't trigger a shrink. `fit=crop` and `fit=shrink` force either behaviour. The scale is never different per axis.
5. **Accepted pages:** 4 × 6 in or 100 × 150 mm (±2 %), portrait or landscape. Landscape is rotated clockwise to portrait, and `/Rotate` is honoured. Anything else, such as a Letter sheet with a label on it, is rejected with an error rather than guessed at.

## Examples

**Pirate Ship UPS label (VOID sample)**
- The template draws a 2-dot frame on the page edge and puts text within ~1 mm of it.
- At 100 % the crop would cut the tops of the sender-address letters, the footer line, and part of a solid black box. So `auto` chooses **×0.984**, with nothing lost; that's less than half of Pixmate's shrink.
- It printed cleanly: all text complete, solid blacks, sharp barcodes.

**Labels with ≥ ~1.5 mm margins** print at exactly 100 % (`test_page_with_margins_prints_at_100_percent`).

**Scan-test label** (`fixtures/scan-test-4x6.pdf`)
- Real Code 128 barcodes: UPS's published example tracking number `1Z999AA10123456784` at 15 mil and 10 mil, and a `420`+ZIP code upright and rotated.
- It prints at 100 %, and every bar comes out an exact multiple of its module width.

## Test fixtures

`scripts/make_fixtures.py` generates:

| File | Purpose |
|---|---|
| `calibration-4x6.pdf/.png` | Border, mm grid and rulers, fine text, a 1-dot checker patch, and a non-live Code 128 |
| `capture-a.png`, `capture-b.png` | Small images that differ in one region, for diffing BLE captures |
| `width-probe-104x150.png` | Full-width bars and mm ruler, for measuring the printable area |
| `scan-test-4x6.pdf` | Decodable barcodes at exact whole-dot module widths |

python-barcode's `ImageWriter` positions bars in rounded millimetres, which turns 2-dot modules into 2/3/5/7-dot bars. So the scan test draws modules itself from the barcode's bit pattern.

The Pirate Ship sample (`fixtures/pirateship-ups-void-4x6.pdf`) isn't redistributed. Download Pirate Ship's sample 4×6 UPS label to that path to enable the optional tests.
