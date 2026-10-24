"""Read-only BLE reconnaissance for the Y813 printer.

Scans for devices whose name contains "Y813", prints advertisement data,
connects, and enumerates the GATT table. Reads only standard SIG
characteristics (0x2Axx: Device Information, GAP). Never writes and never
subscribes to notifications.

Usage: .venv/bin/python scripts/ble_recon.py [--json out.json]
"""

import argparse
import asyncio
import json
import sys
from datetime import datetime, timezone

from bleak import BleakClient, BleakScanner

SIG_BASE = "-0000-1000-8000-00805f9b34fb"


def is_sig_2a(uuid: str) -> bool:
    u = uuid.lower()
    return u.startswith("00002a") and u.endswith(SIG_BASE)


async def main(json_path: str | None) -> int:
    print("Scanning 12s ...", file=sys.stderr)
    found = await BleakScanner.discover(timeout=12, return_adv=True)
    matches = [(d, a) for d, a in found.values()
               if (a.local_name or d.name or "").upper().find("Y813") >= 0]
    if not matches:
        print("No Y813 device found. Is the printer on and Pixmate disconnected?")
        return 1

    report = {"captured_at": datetime.now(timezone.utc).isoformat(), "devices": []}
    for device, adv in matches:
        entry = {
            "name": adv.local_name or device.name,
            "corebluetooth_id": device.address,
            "rssi": adv.rssi,
            "tx_power": adv.tx_power,
            "adv_service_uuids": adv.service_uuids,
            "manufacturer_data": {str(k): v.hex() for k, v in adv.manufacturer_data.items()},
            "service_data": {k: v.hex() for k, v in adv.service_data.items()},
            "services": [],
        }
        print(f"Found {entry['name']} id={device.address} rssi={adv.rssi}", file=sys.stderr)

        async with BleakClient(device, timeout=20) as client:
            entry["mtu_size"] = getattr(client, "mtu_size", None)
            for service in client.services:
                s = {"uuid": service.uuid, "description": service.description,
                     "characteristics": []}
                for char in service.characteristics:
                    c = {
                        "uuid": char.uuid,
                        "handle": char.handle,
                        "description": char.description,
                        "properties": char.properties,
                        "max_write_without_response_size":
                            getattr(char, "max_write_without_response_size", None),
                        "descriptors": [{"uuid": d.uuid, "handle": d.handle,
                                         "description": d.description}
                                        for d in char.descriptors],
                    }
                    if "read" in char.properties and is_sig_2a(char.uuid):
                        try:
                            raw = await client.read_gatt_char(char)
                            c["value_hex"] = raw.hex()
                            c["value_text"] = raw.decode("utf-8", "replace")
                        except Exception as e:  # noqa: BLE001
                            c["read_error"] = repr(e)
                    s["characteristics"].append(c)
                entry["services"].append(s)
        report["devices"].append(entry)

    out = json.dumps(report, indent=2)
    print(out)
    if json_path:
        with open(json_path, "w") as f:
            f.write(out + "\n")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    args = ap.parse_args()
    sys.exit(asyncio.run(main(args.json)))
