# Y813 BLE print protocol

This is what the NULLTONEX Y813 accepts over Bluetooth LE, as observed from the vendor app (Pixmate 1.0.6) with an Apple PacketLogger HCI capture. See [capturing.md](capturing.md) for how the capture was made.

Confidence: the encoder in `src/y813/tspl.py` (and its Swift port) reproduces all five captured Pixmate jobs **byte for byte** (`tests/golden/`, `tests/test_tspl_golden.py`, `tests/test_swift_port.py`).

## Transport

| Item | Value |
|---|---|
| Advertised name | `Y813_XXXX_BLE` (the last four hex digits differ per unit) |
| Service | ISSC / Microchip Transparent UART `49535343-FE7D-4AE5-8FA9-9FAFD205E455` |
| Host → printer | `49535343-8841-43F4-A8D4-ECBE34729BB3` (ATT value handle 0x000D), **Write Without Response** |
| Printer → host | `49535343-1E4D-4BD9-BA61-23C647249616` (value handle 0x000A), notifications |
| ATT MTU | 247 (requested by the printer), so 244-byte write payloads |
| Security | None: no pairing, no link encryption, no application-layer handshake |

The printer also exposes ISSC `ACA3`, a vendor `18F0` service (`2AF0`/`2AF1`), and `E7810A71…/BEF8D6C9…`. Pixmate doesn't use them for this model. The full table is in [gatt-map.md](gatt-map.md).

Connect sequence: connect → the printer sends an MTU request (247) → the host enables notifications (writes `01 00` to the CCCD at 0x000B). That's all; there's no model query or authentication.

## Job format

A job is plain **TSPL** text with compressed bitmaps. It's sent as one byte stream, chunked into 244-byte writes with no alignment to command boundaries:

```
CLS\r\n
DENSITY 11\r\n                       first write is exactly these 17 bytes, then ~600 ms pause
SIZE 100 mm,150 mm\r\n               (Pixmate sends 98 mm; see Geometry)
GAP 2 mm,0 mm\r\n
REFERENCE 0,0\r\n
SET TEAR ON\r\n
SET RESPONSE ON\r\n
CLS\r\n
BITMAP 0,<y>,<width_bytes>,<rows>,3,<zlen>,<zlib data>     repeated per band, nothing between bands
...
PRINT 1,1\r\n
1B 21 3F                             ESC ! ?  (status query)
```

### `BITMAP` mode 3 (zlib)

`BITMAP x,y,width_bytes,height_rows,3,compressed_length,<data>`

- `data` is a standard zlib stream (`78 9C`, default compression level, with an Adler-32 trailer). It decompresses to exactly `width_bytes × height_rows` bytes.
- **Bit 1 = black dot, 0 = white.** The MSB is the leftmost dot, and blank areas are `0x00`. This is the inverse of the classic TSPL `BITMAP` convention.
- Pixmate sends bands of 188 rows (plus a remainder). It's not known whether the printer needs that limit; the encoders keep it.
- There's no terminator after the data.

### Geometry

- 8 dots/mm (203 dpi). The `SIZE` width × height in mm gives the canvas in dots (×8).
- **The printer centers the `SIZE` canvas horizontally on the media.** A 104 mm canvas loses ~2 mm on each side of a 100 mm label, and Pixmate's 98 mm canvas leaves ~1 mm margins. This project uses `SIZE 100 mm,150 mm`, i.e. the label itself (800 × 1200 dots).
- `GAP 2 mm,0 mm` with a 150 mm height feeds the 100 × 150 mm labels correctly.

### Settings

| Pixmate setting | On the wire |
|---|---|
| Density Light / Medium / Dark | `DENSITY 8`* / `11` / `14` (*Light is inferred from the step size) |
| X / Y offset | No command: Pixmate shifts the raster itself (`REFERENCE` stays `0,0`) |
| Text Mode / Dithering | Host-side image conversion only |

TSPL allows `DENSITY 0`–`15`. Intermediate values (such as 12) are accepted.

### Pacing

- After the first 17-byte write, Pixmate waits ~600 ms. The cause isn't known; the encoders copy it.
- The remaining writes go out as fast as CoreBluetooth's write-without-response flow control allows (`canSendWriteWithoutResponse` / `peripheralIsReady`). That's ~6 ms apart, or bursts of 4 per connection interval. There's no application-level ACK.
- A full 4×6 label (~12–15 KB compressed) is on the air in about 1.5 s.

### Status

- `ESC ! ?` gets back one notification byte. `0x00` was the only value seen, arriving 35–210 ms after the query, which is before the label finishes, so it means "ready", not "done".
- Other values are assumed to follow classic TSPL (unverified on this model): `0x01` head open, `0x02` paper jam, `0x04` out of paper, `0x08` out of ribbon, `0x10` paused, `0x20` printing, `0x40` cover open, `0x80` other error.

## Open questions

- Is the 600 ms pause after `CLS/DENSITY` needed?
- Is 188 rows the maximum band height?
- What status bytes come back for paper-out or lid-open, and is there a print-completion signal?
