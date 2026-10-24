"""BLE transport for the Y813, mirroring Pixmate's observed traffic (docs/protocol.md).

Must run under a process that holds a Bluetooth TCC grant (e.g. Terminal.app);
macOS kills processes launched from apps without NSBluetoothAlwaysUsageDescription.
"""

import asyncio

from bleak import BleakClient, BleakScanner

ISSC_WRITE = "49535343-8841-43f4-a8d4-ecbe34729bb3"   # value handle 0x000D
ISSC_NOTIFY = "49535343-1e4d-4bd9-ba61-23c647249616"  # value handle 0x000A
CHUNK = 244            # ATT MTU 247 - 3
HEADER_PAUSE_S = 0.6   # Pixmate pauses after the first "CLS/DENSITY" write

# Classic TSPL <ESC>!? status bits. Unverified on the Y813 except 0x00 = ready.
STATUS_BITS = {
    0x01: "head open", 0x02: "paper jam", 0x04: "out of paper", 0x08: "out of ribbon",
    0x10: "paused", 0x20: "printing", 0x40: "cover open", 0x80: "other error",
}


def describe_status(b: int) -> str:
    if b == 0:
        return "ready (0x00)"
    return f"0x{b:02X}: " + ", ".join(v for k, v in STATUS_BITS.items() if b & k) + " (unverified)"


def plan_writes(job: bytes) -> list[bytes]:
    """First write = the leading "CLS\\r\\nDENSITY n\\r\\n" lines; the rest in 244-byte chunks."""
    first_end = job.find(b"\r\n", job.find(b"DENSITY")) + 2 if b"DENSITY" in job[:32] else 0
    writes = [job[:first_end]] if first_end else []
    rest = job[first_end:]
    writes += [rest[i:i + CHUNK] for i in range(0, len(rest), CHUNK)]
    return writes


async def find_printer(name_prefix: str = "Y813", timeout: float = 10.0):
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: (adv.local_name or d.name or "").startswith(name_prefix), timeout=timeout)
    if device is None:
        raise RuntimeError(f"no BLE device named {name_prefix}* found; is it on and Pixmate quit?")
    return device


async def send_job(job: bytes, *, name_prefix: str = "Y813", pace_s: float = 0.006,
                   status_timeout_s: float = 5.0, log=print) -> int | None:
    """Send one job; return the status byte from the trailing ESC!? (or None on timeout)."""
    device = await find_printer(name_prefix)
    log(f"connecting to {device.name} ({device.address})")
    status: asyncio.Queue[bytes] = asyncio.Queue()

    async with BleakClient(device, timeout=20) as client:
        await client.start_notify(ISSC_NOTIFY, lambda _c, data: status.put_nowait(bytes(data)))
        writes = plan_writes(job)
        log(f"sending {len(job)} bytes in {len(writes)} writes")
        for i, w in enumerate(writes):
            await client.write_gatt_char(ISSC_WRITE, w, response=False)
            await asyncio.sleep(HEADER_PAUSE_S if i == 0 and w.startswith(b"CLS") else pace_s)
        try:
            data = await asyncio.wait_for(status.get(), status_timeout_s)
        except asyncio.TimeoutError:
            log("no status notification received")
            return None
        log(f"status: {describe_status(data[0])} raw={data.hex()}")
        return data[0]
