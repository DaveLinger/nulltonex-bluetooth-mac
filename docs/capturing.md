# Reproducing the protocol capture

How the protocol in [protocol.md](protocol.md) was observed. Pixmate wasn't modified or decompiled: its strings were read statically (see [app-inspection.md](app-inspection.md)), and its BLE traffic was recorded on the Mac it runs on.

## 1. BLE reconnaissance (read-only)

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
open -a Terminal scripts/run_recon.command
```

`scripts/ble_recon.py` scans for `Y813*`, connects, and dumps the GATT table. It only reads; it never writes or subscribes. The output is in [gatt-map.md](gatt-map.md).

**Run BLE scripts from Terminal.app.** macOS kills (SIGABRT) any process that touches CoreBluetooth without a usage description on its "responsible" app. That includes processes started from a shell inside an IDE or agent app. Terminal.app asks for Bluetooth permission once.

## 2. HCI capture with PacketLogger

PacketLogger records the HCI stream between macOS and the Bluetooth controller. BLE link encryption happens inside the controller, below HCI, so ATT payloads are readable. Pixmate isn't touched.

1. Install **PacketLogger** from *Additional Tools for Xcode* (developer.apple.com/download).
2. Install Apple's **Bluetooth logging profile** for macOS (developer.apple.com/bug-reporting/profiles-and-logs) and restart. On macOS 27, PacketLogger's trace stays empty without it.
3. In PacketLogger, choose File → New MacOS Trace.
4. In Pixmate, connect to the printer and print the fixtures at least 10 s apart:
   - `capture-a.png`, `capture-b.png`, `calibration-4x6.pdf`
   - then `capture-a.png` again with one setting changed (density, X offset)
5. Save the trace as `captures/<name>.pklg`. Remove the logging profile afterwards (System Settings → General → Device Management).

The trace includes **all** of the Mac's Bluetooth traffic, including other devices. Don't publish it; `captures/` is git-ignored.

## 3. Analysis

```bash
.venv/bin/python scripts/pklg_extract.py captures/<name>.pklg --out captures/extract
.venv/bin/python scripts/tspl_decode.py captures/extract/job02_tx_WRITE_CMD_h000D.bin --png job02.png
```

- `pklg_extract.py` reassembles HCI ACL fragments into L2CAP/ATT and splits jobs on idle gaps. It writes one stream per (job, direction, opcode, handle) and prints write sizes and timing.
- `tspl_decode.py` splits a stream into TSPL commands, decompresses the `BITMAP` bands, and renders the label as a PNG.

Diffing one-change variants (A vs B, A vs density+1, A vs X+1 mm) identified each command and the raster encoding. The extracted printer streams (test images only) are kept as `tests/golden/pixmate-*.bin`.

## 4. Sending test jobs without Pixmate

```bash
.venv/bin/python scripts/y813_send.py --replay tests/golden/pixmate-capture-a.bin --dry-run
.venv/bin/python scripts/make_job.py fixtures/width-probe-104x150.png --width-mm 104 --height-mm 150 --out jobs/next.bin
open -a Terminal scripts/send_job.command        # sends jobs/next.bin
```
