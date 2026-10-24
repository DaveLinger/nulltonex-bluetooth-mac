# Y813 BLE GATT map

Captured 2026-10-24 with `scripts/ble_recon.py` (bleak 3.0.2, CoreBluetooth, macOS 27.0.1, Apple M2). Raw output: [`tests/golden/gatt-recon.json`](../tests/golden/gatt-recon.json).

Method: scan → connect → enumerate. **No writes, no notification subscriptions.** Only SIG `0x2Axx` characteristics with the `read` property were eligible to be read, and the printer exposes none that are readable.

## Advertisement

| Field | Value |
|---|---|
| Local name | `Y813_56F7_BLE` |
| CoreBluetooth ID | host-specific UUID (not a MAC address; don't hard-code it) |
| RSSI / TX power | −61 dBm / 5 dBm |
| Advertised services | `18F0`, `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2` |
| Manufacturer / service data | none |

## Connection

- Connected without a pairing prompt. Enumeration did not require bonding or encryption.
- CoreBluetooth reports ATT MTU **247**, so `maximumWriteValueLength(withoutResponse)` is **244 bytes**. Measured, not assumed. Pixmate's traffic later confirmed 244-byte write-without-response chunks ([protocol.md](protocol.md)).
- No Device Information (`180A`) or Battery (`180F`) service, so firmware and DPI must come from the printer label, the app, or a vendor status command.
- Multiple simultaneous centrals: **not tested yet**. Pixmate was not running.

## Services and characteristics

| Service | Characteristic | Handle | Properties | CCCD | Notes |
|---|---|---|---|---|---|
| `49535343-FE7D-4AE5-8FA9-9FAFD205E455` (Microchip/ISSC Transparent UART) | `49535343-1E4D-4BD9-BA61-23C647249616` | 9 | notify | 11 | UART TX (printer → host) |
| | `49535343-8841-43F4-A8D4-ECBE34729BB3` | 12 | write, write-without-response | — | UART RX (host → printer); likely bulk data path |
| | `49535343-ACA3-481C-91EC-D85E28A60318` | 14 | notify, write | 16 | ISSC control/credit channel (flow control) |
| `000018F0-…` (vendor, 16-bit) | `00002AF1-…` | 18 | notify | 20 | Vendor UART TX/status. bleak's "Electric Current Statistics" label is just the SIG name for 0x2AF1 and is meaningless here. |
| | `00002AF0-…` | 21 | write, write-without-response | — | Vendor UART RX; second candidate data path |
| `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2` (vendor) | `BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F` | 24 | notify, read, write | 26 | Single bidirectional channel. The Pixmate binary pairs this UUID with `ServiceName/TxName/RxName`, so it is probably the app's primary transport for this model family. Write-with-response only, so it is slower. |

All three service UUIDs appear verbatim in the Pixmate binary (see [app-inspection.md](app-inspection.md)).

## Resolved by the capture

Pixmate uses only the ISSC service for the Y813: it writes to `8841` (value handle 0x000D, write-without-response) and gets status notifications on `1E4D` (0x000A). There's no handshake or authentication. bleak reports **declaration** handles, so the ATT value handle is the declaration handle + 1. Details are in [protocol.md](protocol.md).

The enumeration was read-only: no GATT writes, and no notifications enabled.
