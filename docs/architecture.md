# Architecture: macOS Print dialog → Y813

```
Preview / Chrome / Pirate Ship ──► macOS Print dialog ──► CUPS queue "Y813" (IPP Everywhere, built-in ipp backend)
        ──► ipp://127.0.0.1:8631/ipp/print
        ──► Y813PrintService.app  (per-user LaunchAgent, holds the Bluetooth permission)
              IPP server ─► PDF → 800×1200 1-bit raster ─► TSPL + zlib ─► CoreBluetooth ─► printer
```

## Why this shape

- **No custom CUPS backend.** On current macOS, CUPS backends live in `/usr/libexec/cups/backend`, which is protected by System Integrity Protection. (The built-in `bluetooth` backend is for Classic/RFCOMM printers, not BLE.)
- **Bluetooth needs an app bundle.** CoreBluetooth access is gated by TCC, and the process needs `NSBluetoothAlwaysUsageDescription`. cupsd and its filters can't hold the grant. A bare script launched from a terminal inside another app is killed with SIGABRT. So the Bluetooth side is a small signed app.
- **IPP Everywhere does the rest.** The app is a local IPP printer. `lpadmin -m everywhere` builds the queue from the attributes it advertises. Because it advertises `application/pdf`, CUPS hands over the job PDF unchanged (`*cupsFilter2: "application/vnd.cups-pdf application/pdf 10 -"`), and the app renders it itself on the printer's dot grid.

## The app (`macos/Sources/`)

| File | Role |
|---|---|
| `main.swift` | `serve` (default) plus `render` / `encode` / `print` subcommands used by the tests |
| `HTTPServer.swift` | Blocking HTTP/1.1 on 127.0.0.1 only: keep-alive, chunked bodies, `Expect: 100-continue` |
| `IPP.swift` | IPP message codec (RFC 8010), including collections |
| `PrinterService.swift` | Printer attributes, job table, serial print worker |
| `Raster.swift` | CoreGraphics PDF rendering and fit policy ([rendering.md](rendering.md)) |
| `TSPL.swift` | Job encoder (system zlib via `bridge.h`) |
| `BLE.swift` | CoreBluetooth sender |

Supported IPP operations: Print-Job, Validate-Job, Cancel-Job (pending jobs), Get-Job-Attributes, Get-Jobs, Get-Printer-Attributes.

Advertised capabilities:
- media `na_index-4x6_4x6in` (default) and `om_small-photo_100x150mm`, both borderless
- 203 dpi, monochrome
- `print-quality` draft / normal / high

## Behaviour

- **One job at a time.** For each job the app connects (scanning the first time, then reusing the known peripheral), sends, waits for the `ESC ! ?` status byte, and disconnects. Pixmate can still connect between jobs.
- **Never prints twice.** A job is retried (3 attempts, 5 s apart) only if it failed *before* the first data write: printer not found, connect failure, and so on. A failure mid-transfer aborts the job with a message and is not retried.
- **Darkness** comes from the Print dialog's *Print Quality* option: Draft → `DENSITY 8`, Normal → `11`, High → `14`, matching Pixmate's Light/Medium/Dark. The LaunchAgent's `--density N` sets the Normal value, and Draft/High stay 3 steps either side (clamped to 0–15).
- **Status mapping:** non-zero status bits become IPP reasons (`media-empty`, `cover-open`, …) and the job is aborted. Only `0x00` has been observed on real hardware.
- **Privacy:** label content is never logged, and PDFs stay in memory only until the job finishes. The log is `~/Library/Logs/Y813PrintService.log`.
- **Pages:** each page of a PDF prints as one label. Pages that aren't 4×6 in or 100×150 mm (±2 %, either orientation) are rejected with a `job-state-message`.

## Python reference implementation

`src/y813/` (`tspl.py`, `raster.py`, `ble.py`) plus `scripts/y813_print.py` came first and remain the reference. The Swift code is a port, and `tests/test_swift_port.py` checks it against Python:
- the encoder is byte-identical
- the renderer matches on size, scale and rotation, with identical barcode bar widths, and differs only on anti-aliased edges

## Known limitations

- **Bluetooth permission prompt.** A launchd-started instance may never show the permission prompt, so `install.sh` first runs `Y813PrintService authorize` through LaunchServices (`open -W`). That shows the prompt, waits for the answer, and only then loads the LaunchAgent.
- **Ad-hoc signing.** Releases are ad-hoc signed (no paid Developer ID), so they're installed from Terminal rather than double-clicked. Files fetched with `curl` aren't quarantined. macOS may re-ask for Bluetooth permission after an update.
- **Media.** Only 100 × 150 mm label stock is tested. Other sizes would need new media entries and a new `SIZE`.
