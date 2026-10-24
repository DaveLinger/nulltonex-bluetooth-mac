"""TSPL job encoder for the Y813, matching what Pixmate 1.0.6 sends (see docs/protocol.md).

The image is 1-bit, already at printer resolution (8 dots/mm). No scaling happens here.
"""

import zlib

from PIL import Image

DOTS_PER_MM = 8
BAND_ROWS = 188  # Pixmate's band height (98 B x 188 rows = 18,424 B per BITMAP)
STATUS_QUERY = b"\x1b!?"


def bitmap_bytes(img: Image.Image) -> bytes:
    """Pack a mode-"1" image as Y813 raster: MSB = leftmost dot, bit 1 = black."""
    if img.mode != "1":
        raise ValueError("image must be mode '1'")
    if img.width % 8:
        raise ValueError("image width must be a multiple of 8 dots")
    # PIL packs mode "1" with bit 1 = white; invert.
    return bytes(b ^ 0xFF for b in img.tobytes())


def encode_job(img: Image.Image, *, width_mm: int, height_mm: int, density: int = 11,
               gap_mm: int = 2, copies: int = 1) -> bytes:
    """Build one complete print job: header, zlib BITMAP bands, PRINT, status query."""
    if not 0 <= density <= 15:
        raise ValueError("density must be 0-15")
    if img.width > width_mm * DOTS_PER_MM or img.height > height_mm * DOTS_PER_MM:
        raise ValueError(f"image {img.size} exceeds label {width_mm}x{height_mm} mm")
    wb = img.width // 8
    raster = bitmap_bytes(img)

    out = bytearray()
    out += f"CLS\r\nDENSITY {density}\r\n".encode()
    out += (f"SIZE {width_mm} mm,{height_mm} mm\r\n"
            f"GAP {gap_mm} mm,0 mm\r\n"
            "REFERENCE 0,0\r\n"
            "SET TEAR ON\r\n"
            "SET RESPONSE ON\r\n"
            "CLS\r\n").encode()
    for y in range(0, img.height, BAND_ROWS):
        rows = min(BAND_ROWS, img.height - y)
        comp = zlib.compress(raster[y * wb:(y + rows) * wb])
        out += f"BITMAP 0,{y},{wb},{rows},3,{len(comp)},".encode() + comp
    out += f"PRINT 1,{copies}\r\n".encode() + STATUS_QUERY
    return bytes(out)


def chunks(job: bytes, size: int = 244):
    """Split a job into BLE write-without-response payloads (ATT MTU 247 -> 244)."""
    for i in range(0, len(job), size):
        yield job[i:i + size]
