# y813-macos-print

Print 4×6 shipping labels from the **standard macOS Print dialog** to a **NULLTONEX Y813** thermal label printer over **Bluetooth LE**. You don't need the vendor's Pixmate app or a USB cable.

It's a small native macOS app that shows up as a regular printer called **Y813 Label Printer**. Print a label PDF from Preview, Chrome, Pirate Ship or any other app, and it goes to the printer over BLE at the printer's native 203 dpi, without the shrinking Pixmate applies.

```
App ─► Print dialog ─► CUPS queue "Y813" ─► ipp://127.0.0.1:8631 ─► Y813PrintService.app ─► BLE ─► Y813
```

## Status

Works end to end. It was developed and tested on:
- macOS 27.0.1 on an Apple M2
- a NULLTONEX Y813 (`Y813_XXXX_BLE`) with 100 × 150 mm labels
- printing from Chrome, Preview and `lp`

Other macOS versions and other label sizes are untested.

## Requirements

- macOS on a Mac with Bluetooth LE
- Xcode **Command Line Tools** (`xcode-select --install`), for `swiftc`. Full Xcode isn't needed.
- An admin account, to add the print queue

## Install

```bash
git clone https://github.com/DaveLinger/y813-macos-print.git
cd y813-macos-print
macos/install.sh --queue
```

This does three things:
- builds `Y813PrintService.app` and installs it to `~/Applications`
- starts it at login with a LaunchAgent (`local.y813.printservice`)
- adds a CUPS queue named **Y813** (IPP Everywhere, pointing at `ipp://127.0.0.1:8631/ipp/print`)

When macOS asks whether **Y813 Print Service** may use Bluetooth, click **Allow**. If no prompt appears, see [Troubleshooting](#troubleshooting).

## Printing

1. Turn the printer on. Quit Pixmate, since the printer accepts one connection at a time.
2. Open the label PDF and choose **Print** → **Y813 Label Printer**.
3. Set **Paper size: 4 × 6 in** (the default), and keep scaling at **Default / 100 %**. Don't use "fit to page": the service does its own fitting.
4. Optional: **Print Quality** sets darkness.

| Print Quality | TSPL `DENSITY` | Pixmate equivalent |
|---|---|---|
| Draft | 8 | Light |
| **Normal** (default) | **11** | Medium |
| High | 14 | Dark |

Chrome's built-in dialog doesn't show Print Quality. Use *Print using system dialog… (⌥⌘P)* to get it.

From the command line:

```bash
lp -d Y813 label.pdf
lp -d Y813 -o print-quality=5 label.pdf    # High
```

### How labels are fitted

Label PDFs are usually exactly 4 × 6 in (101.6 × 152.4 mm), while the Y813's labels are 100 × 150 mm. The service renders the PDF directly at 8 dots/mm and prints it at **100 %**, centered. It shrinks only if real content would otherwise be cut off. That shrink is uniform and redrawn from the vector PDF, typically to about 98.4 %. Page-edge frame lines don't count as content. Details: [docs/rendering.md](docs/rendering.md).

Accepted pages are 4 × 6 in or 100 × 150 mm, portrait or landscape. Other sizes (for example a Letter sheet) are rejected with an error rather than printed wrong.

## Configuration

The Normal density lives in the LaunchAgent's arguments; Draft and High stay 3 steps either side. To make Normal 12:

```bash
plutil -replace ProgramArguments.3 -string 12 ~/Library/LaunchAgents/local.y813.printservice.plist
launchctl bootout gui/$(id -u)/local.y813.printservice
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.y813.printservice.plist
```

## Troubleshooting

- **Log:** `~/Library/Logs/Y813PrintService.log` records each job's scale, any cropping, the BLE steps and the status byte. It never records label content.
- **Job failed:** `lpstat -W completed -l -o Y813` shows CUPS's view. The service's reason (for example "printer not found") is in the log.
- **No Bluetooth prompt / "timed out waiting for Bluetooth":** launch the app once through LaunchServices, click Allow, then restart the agent:
  ```bash
  launchctl bootout gui/$(id -u)/local.y813.printservice
  open -a ~/Applications/Y813PrintService.app --args serve
  ```
  After you click Allow:
  ```bash
  pkill -f Y813PrintService.app; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.y813.printservice.plist
  ```
  You can review the permission in System Settings → Privacy & Security → Bluetooth.
- **"Printer not found":** the printer is off, out of range, or still connected to Pixmate (or a phone).
- **A failed job never reprints on its own.** The service retries only failures that happened before any data was sent, so a paid label can't print twice.

## Uninstall

```bash
macos/install.sh --uninstall    # removes the queue, the LaunchAgent and the app
```

## How it works

| Doc | Contents |
|---|---|
| [docs/protocol.md](docs/protocol.md) | The Y813 BLE protocol: ISSC UART service, TSPL with zlib `BITMAP` mode 3, inverted bit polarity, pacing, status |
| [docs/architecture.md](docs/architecture.md) | Why it's a local IPP printer app, what the service does, and its guarantees |
| [docs/rendering.md](docs/rendering.md) | Label geometry, crop/shrink policy, test fixtures |
| [docs/gatt-map.md](docs/gatt-map.md) | The printer's GATT table |
| [docs/app-inspection.md](docs/app-inspection.md) | What Pixmate's binary revealed (static strings only) |
| [docs/capturing.md](docs/capturing.md) | How the protocol was captured with PacketLogger, and how to reproduce it |

## Development

```
macos/            Swift print service (build.sh, install.sh, Sources/)
src/y813/         Python reference: tspl.py (encoder), raster.py (PDF → raster), ble.py (bleak sender)
scripts/          y813_print.py (PDF → job / send), research tools (recon, pklg extractor, TSPL decoder, fixtures)
tests/            unittest suite; tests/golden/ holds the byte streams Pixmate sent (test images only)
fixtures/         generated test labels
```

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
macos/build.sh                                  # needed for the Swift parity tests
.venv/bin/python -m unittest discover -s tests
```

The Swift encoder must stay **byte-identical** to Pixmate's captured jobs and the Python encoder, and the renderers must agree (`tests/test_swift_port.py`). Three optional tests use Pirate Ship's sample UPS label. Save it as `fixtures/pirateship-ups-void-4x6.pdf` to enable them; it isn't redistributed here.

Python scripts that use Bluetooth must run from **Terminal.app**, not from a shell inside another app (IDE, agent), or macOS kills them. See [docs/capturing.md](docs/capturing.md).

## Disclaimer

This is an independent project, not affiliated with or endorsed by NULLTONEX, the makers of Pixmate, Pirate Ship or UPS. The protocol was worked out for interoperability from the printer's own Bluetooth traffic. Pixmate wasn't modified or decompiled, and no firmware was touched. Use at your own risk.

## License

[MIT](LICENSE)
