# y813-macos-print

Print 4×6 shipping labels from the **standard macOS Print dialog** to a **NULLTONEX Y813** thermal label printer over **Bluetooth LE**. You don't need the vendor's Pixmate app or a USB cable.

It's a small native macOS app that shows up as a regular printer called **Y813 Label Printer**. Print a label PDF from Preview, Chrome, Pirate Ship or any other app, and it goes to the printer over BLE at the printer's native 203 dpi, without the shrinking Pixmate applies.

## Install

Open **Terminal** and run:

```bash
curl -fsSL https://raw.githubusercontent.com/DaveLinger/y813-macos-print/main/install.sh | zsh
```

The installer:
1. downloads the latest release of **Y813PrintService.app** to `~/Applications`
2. asks macOS for Bluetooth permission; **click Allow** when "Y813 Print Service" asks to use Bluetooth
3. starts a small background service that runs at login
4. adds a printer called **Y813 Label Printer**

Run the same command again to update. To remove everything:

```bash
curl -fsSL https://raw.githubusercontent.com/DaveLinger/y813-macos-print/main/install.sh | zsh -s -- --uninstall
```

If you'd rather not pipe a script into your shell, download `install.sh` and `Y813PrintService.zip` from the [latest release](https://github.com/DaveLinger/y813-macos-print/releases/latest), read the script, then run `zsh install.sh --app ~/Downloads/Y813PrintService.zip`.

The app is open source and ad-hoc signed, not signed with a paid Apple Developer ID. Installing through Terminal avoids the Gatekeeper "unidentified developer" block that a double-clicked download would hit.

### Requirements

- A Mac with Bluetooth, Intel or Apple Silicon. Developed on macOS 27, earlier versions untested.
- An admin account, to add the printer
- A NULLTONEX Y813 with 100 × 150 mm (4 × 6) labels

No Xcode or developer tools are needed, and neither is Pixmate.

## Pairing: none needed

The Y813 doesn't use Bluetooth pairing. **Don't pair it in System Settings, and you don't need Pixmate.** Turn the printer on and print: the service finds any printer advertising as `Y813_…` and connects for each job.

**Security note:** with no pairing, anyone within Bluetooth range (roughly 10 m) can send the printer a job while nothing else is connected to it. That's how the printer's firmware works, whatever app you use. The practical risk is wasted labels, since the printer stores no data. This service connects only while printing.

## Printing

1. Turn the printer on.
2. Open the label PDF and choose **Print** → **Y813 Label Printer**.
3. Set **Paper size: 4 × 6 in** (the default), and keep scaling at **Default / 100 %**. Don't use "fit to page": the service does its own fitting.
4. Optional: **Print Quality** sets darkness.

| Print Quality | TSPL `DENSITY` | Pixmate equivalent |
|---|---|---|
| Draft | 8 | Light |
| **Normal** (default) | **11** | Medium |
| High | 14 | Dark |

Chrome's built-in dialog doesn't show Print Quality. Use *Print using system dialog… (⌥⌘P)* to get it.

### How labels are fitted

Label PDFs are usually exactly 4 × 6 in (101.6 × 152.4 mm), while the Y813's labels are 100 × 150 mm. The service renders the PDF directly at 8 dots/mm and prints it at **100 %**, centered. It shrinks only if real content would otherwise be cut off. That shrink is uniform and redrawn from the vector PDF, typically to about 98.4 %. Page-edge frame lines don't count as content. Details: [docs/rendering.md](docs/rendering.md).

Accepted pages are 4 × 6 in or 100 × 150 mm, portrait or landscape. Other sizes (for example a Letter sheet) are rejected with an error rather than printed wrong.

## Troubleshooting

- **Log:** `~/Library/Logs/Y813PrintService.log` records each job's scale, any cropping, the BLE steps and the status byte. It never records label content.
- **Job failed:** `lpstat -W completed -l -o Y813` shows CUPS's view. The service's reason (for example "printer not found") is in the log.
- **"timed out waiting for Bluetooth" / "Bluetooth permission not granted":** turn on **Y813PrintService** in System Settings → Privacy & Security → Bluetooth, then run the install command again.
- **"Printer not found":** the printer is off or out of range, or another device is connected to it.
- **Only one connection at a time:** the printer accepts a single Bluetooth connection. If another device or app, such as a phone, is connected to it, the Mac can't reach it. Disconnect the other device and print again. This service connects only while a job is printing, so it won't block other devices between jobs.
- **A failed job never reprints on its own.** The service retries only failures that happened before any data was sent, so a paid label can't print twice.

## How it works

```
App ─► Print dialog ─► CUPS queue "Y813" ─► ipp://127.0.0.1:8631 ─► Y813PrintService.app ─► BLE ─► Y813
```

The app is a small local print server. macOS's print system hands it the label PDF, and it renders the PDF at the printer's 203 dpi and sends it over Bluetooth LE.

| Doc | Contents |
|---|---|
| [docs/protocol.md](docs/protocol.md) | The Y813 BLE protocol: ISSC UART service, TSPL with zlib `BITMAP` mode 3, inverted bit polarity, pacing, status |
| [docs/architecture.md](docs/architecture.md) | Why it's a local IPP printer app, what the service does, and its guarantees |
| [docs/rendering.md](docs/rendering.md) | Label geometry, crop/shrink policy, test fixtures |
| [docs/gatt-map.md](docs/gatt-map.md) | The printer's GATT table |
| [docs/app-inspection.md](docs/app-inspection.md) | What Pixmate's binary revealed (static strings only) |
| [docs/capturing.md](docs/capturing.md) | How the protocol was captured with PacketLogger, and how to reproduce it |

### Tested with

Developed and tested on:
- macOS 27.0.1 on an Apple M2
- a NULLTONEX Y813 (`Y813_XXXX_BLE`) with 100 × 150 mm labels
- printing from Chrome, Preview and `lp`

Other macOS versions and other label sizes are untested.

## Development

```
install.sh        installer (downloads the release, or --from-source)
macos/            Swift print service (build.sh, Sources/)
src/y813/         Python reference: tspl.py (encoder), raster.py (PDF → raster), ble.py (bleak sender)
scripts/          y813_print.py (PDF → job / send), research tools (recon, pklg extractor, TSPL decoder, fixtures)
tests/            unittest suite; tests/golden/ holds the byte streams Pixmate sent (test images only)
fixtures/         generated test labels
```

Building from source needs the Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/DaveLinger/y813-macos-print.git && cd y813-macos-print
./install.sh --from-source                      # build this checkout and install it

python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
macos/build.sh                                  # universal app (add "native" for a faster single-arch build)
.venv/bin/python -m unittest discover -s tests
```

**Releases:** bump `VERSION`, commit, then push a matching tag (`git tag v0.1.1 && git push --tags`). GitHub Actions builds the universal app, runs the tests, and publishes `Y813PrintService.zip` plus `install.sh`.

The Swift encoder must stay **byte-identical** to Pixmate's captured jobs and the Python encoder, and the renderers must agree (`tests/test_swift_port.py`). Three optional tests use Pirate Ship's sample UPS label. Save it as `fixtures/pirateship-ups-void-4x6.pdf` to enable them; it isn't redistributed here.

Python scripts that use Bluetooth must run from **Terminal.app**, not from a shell inside another app (IDE, agent), or macOS kills them. See [docs/capturing.md](docs/capturing.md).

## Disclaimer

This is an independent project, not affiliated with or endorsed by NULLTONEX, the makers of Pixmate, Pirate Ship or UPS. The protocol was worked out for interoperability from the printer's own Bluetooth traffic. Pixmate wasn't modified or decompiled, and no firmware was touched. Use at your own risk.

## License

[MIT](LICENSE)
