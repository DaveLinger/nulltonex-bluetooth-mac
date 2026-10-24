# Pixmate app inspection (static, read-only)

Done 2026-10-24 on the App Store build installed on an Apple Silicon Mac. Nothing was modified, decrypted, or decompiled. Evidence comes from `plutil`, `file`, `otool -l`, `xxd`, and `strings`. **Strings are clues, not proof.**

## Packaging

| Item | Value | Confidence |
|---|---|---|
| Path | `/Applications/Pixmate.app` → `Wrapper/Pixmate.app` (`WrappedBundle` symlink) | Confirmed |
| Type | iPhone/iPad App Store app running on Apple Silicon (iOS-on-Mac wrapper) | Confirmed |
| Bundle ID | `com.fyhd.pixmate` | Confirmed |
| Version | 1.0.6 (build 202608241628), iphoneos26.2 SDK, MinimumOSVersion 27.0 | Confirmed |
| Executable | `Pixmate`, Mach-O 64-bit arm64, 55 MB | Confirmed |
| DRM | `ITSDRMScheme v2`, `LC_ENCRYPTION_INFO_64 cryptid 1`, but `cryptsize` is only 4096 bytes, so nearly all of `__TEXT`/cstrings are readable | Confirmed |
| Hardening | Bundle ships `libjiagu.raw` (a stored zip; the name matches a Chinese app-hardening product). Not unpacked. | Observed; purpose unverified |
| Bluetooth | `NSBluetoothAlwaysUsageDescription` present; `UIBackgroundModes` includes `bluetooth-central` and `bluetooth-peripheral` | Confirmed |
| Document types | Owner of `com.adobe.pdf`; alternate for Office/HTML/text | Confirmed |
| Frameworks | AFNetworking, AipBase/AipOcrSdk (Baidu OCR), GSDK, IdcardQuality, ReactiveObjC. No Flutter/RN/JS bridge for printing. | Confirmed |

The bundle also contains third-party analytics/share SDK keys in `Info.plist`; they are irrelevant and deliberately not reproduced here.

## Printing stack (from string tables)

Printing logic is **native Objective-C**, in a vendor SDK with an `AY` prefix plus classes that match a Gprinter-style SDK:

- BLE: `AYBleHelper`, `BLEConnecter`, `BLEManager`, `Connecter`, `BleHelperDelegate`; properties `mtu`, `mtu_response`, `mtu_noResponse`, `mtu_custom`, `mtuCharacteristic`.
- Command builders: `AYTsplCommand`, `TscCommand`, `AYCpclCommand`, `CPCLCommand`, `AYEscCommand`, `GSEscCommand`, `ZplCommand`, `LifePrinterCommand`.
- Status/info: `AYDataAnalyze`, `Vtr_GetDpi`, `Vtr_GetModel`, `Vtr_GetDensity`, `Vtr_GetPaperType_String`, `Vtr_GetBatteryStatus`, `Vtr_GetBluetoothMac`, `Vtr_GetPrintMileage`; app-side `getPrinterDpi`, `getPrinterWidthDpi:`, `sn_getDPIWithDeviceName:`.
- Firmware update: `AYOtaHelper`, `AYOtaHelperCPCL`, `OTACommands`.
- Also: `EthernetConnecter`/`AYGCDAsyncSocket` (Wi-Fi printers), `EASessionController` (MFi accessories).

### TSPL templates present (format strings)

`SIZE %d mm,%d mm` · `GAP %d mm,%d mm` · `GAP 3 mm,0 mm` · `BLINE %d mm,%d mm` · `DENSITY %d` · `SPEED %d` / `SPEED %.1f` · `DIRECTION %d` · `REFERENCE %d,%d` · `BITMAP %d,%d,%d,%d,` · `PRINT %d,%d` · `PRINT 1,%d` · `SET GAP ON/OFF` · `SET TEAR` · `SET PEEL` · `SET CUTTER` · `SELFTEST` · `SET RESPONSE` · `GAP-SENSE`. CPCL templates (`! 0 200 200 %d %d`, `PAGE-WIDTH`, `FORM`) are also present.

### Model catalogue

The UI lists `Y813` next to `Px420` and `Z421` under `biaoqianji` (标签机, "label machine"). Nearby media presets include `100*150` (= 4×6 in), `100*180`, `100*100`, `70*130`, and others. Other models seen: `GE230`, `SK20`, `SK58`.

### Status bytes (hypothesis)

`6572723A14000C0F` and `6572723A1440000F` appear next to `A4PrintStatusNotification`. `6572723A` is ASCII `err:`, so the printer probably sends `err:` plus 4 status bytes on some models. Not verified for the Y813.

## BLE UUIDs embedded in the binary

| UUID | Commonly known as | Role in app (from adjacent strings) |
|---|---|---|
| `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2` | Common vendor printer service | `ServiceName` |
| `BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F` | Its write/notify characteristic | `TxName`/`RxName` |
| `49535343-FE7D-4AE5-8FA9-9FAFD205E455` | Microchip/ISSC "Transparent UART" service | alternate transport |
| `49535343-1E4D-…`, `-8841-…`, `-6DAA-…`, `-ACA3-…` | ISSC TX/RX/control characteristics | `write char` / `notify char` |
| `FF00`, `FF01`, `FF02`, `FF03`, `FF80`–`FF82` | Generic vendor UART-style 16-bit services | alternates |
| `F000FFC0-0451-4000-B000-000000000000` | TI OAD (firmware update) | near BT826/BT986 module names |

The app clearly supports several BLE transports. **Which one the Y813 exposes is decided by the GATT scan, not by this list.**

## Other bundle resources

- `l2v104.PRTU` (56 KB), `x1b.PRTU` (71 KB): start with what looks like an ARM Cortex-M vector table (initial SP `0x2000xxxx`, reset vector `0x0800xxxx`). These are probably firmware images for other models (L2 v1.04, X1B). **Do not touch.**
- `config.aac` (346 KB): opaque data, not inspected.

## Outcome

The strings pointed at TSPL over a UART-style characteristic, and the BLE capture confirmed it. The details that strings couldn't show: the bitmaps use zlib `BITMAP` mode 3, with inverted polarity (1 = black). See [protocol.md](protocol.md).
