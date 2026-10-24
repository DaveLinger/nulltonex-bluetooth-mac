"""Extract ATT traffic from an Apple PacketLogger (.pklg) capture.

Reassembles HCI ACL fragments into L2CAP frames, keeps the ATT channel (CID 4),
and reports writes/notifications per attribute handle. Jobs are split on idle
gaps so each Pixmate print can be diffed separately.

Usage:
  .venv/bin/python scripts/pklg_extract.py captures/pixmate-YYYYMMDD.pklg \
      [--gatt tests/golden/gatt-recon.json] [--gap 3.0] [--out captures/extract]

Writes, per job, one .bin per (direction, handle) with the concatenated values,
and prints a summary with an ASCII preview of each stream.
"""

import argparse
import json
import struct
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

# PacketLogger record types (see Wireshark epan/dissectors/packet-packetlogger.c).
PKT_HCI_COMMAND = 0x00
PKT_HCI_EVENT = 0x01
PKT_ACL_SENT = 0x02
PKT_ACL_RECV = 0x03

ATT_CID = 0x0004

ATT_OPCODES = {
    0x01: "ERROR_RSP",
    0x02: "MTU_REQ",
    0x03: "MTU_RSP",
    0x0A: "READ_REQ",
    0x0B: "READ_RSP",
    0x12: "WRITE_REQ",
    0x13: "WRITE_RSP",
    0x1B: "NOTIFY",
    0x1D: "INDICATE",
    0x1E: "CONFIRM",
    0x52: "WRITE_CMD",
}
# Opcodes whose PDU is: opcode(1) handle(2) value(...)
HANDLE_VALUE_OPS = {0x12, 0x1B, 0x1D, 0x52}


@dataclass
class Record:
    ts: float
    type: int
    payload: bytes


@dataclass
class AttPdu:
    ts: float
    direction: str  # "tx" = host -> printer, "rx" = printer -> host
    conn: int
    opcode: int
    handle: int | None
    value: bytes

    @property
    def op_name(self) -> str:
        return ATT_OPCODES.get(self.opcode, f"OP_{self.opcode:02X}")


def read_records(data: bytes) -> list[Record]:
    """Parse pklg records. Header: len(4) ts(8) type(1); len counts ts+type+payload.

    Classic captures are big-endian; some iOS/macOS captures are little-endian.
    Detect from the first record and fall back to the other order if it fails.
    """
    for endian in (">", "<"):
        try:
            return _read_records(data, endian)
        except ValueError:
            continue
    raise ValueError("not a recognizable PacketLogger file")


def _read_records(data: bytes, endian: str) -> list[Record]:
    out = []
    off = 0
    while off < len(data):
        if off + 13 > len(data):
            raise ValueError("truncated header")
        (length,) = struct.unpack_from(endian + "I", data, off)
        if length < 9 or off + 4 + length > len(data):
            raise ValueError(f"bad record length {length} at {off}")
        secs, usecs = struct.unpack_from(endian + "II", data, off + 4)
        rtype = data[off + 12]
        payload = data[off + 13: off + 4 + length]
        out.append(Record(secs + usecs / 1e6, rtype, payload))
        off += 4 + length
    return out


def reassemble_att(records: list[Record]) -> list[AttPdu]:
    """HCI ACL -> L2CAP -> ATT, handling start/continuation fragments per direction."""
    pending: dict[tuple[str, int], tuple[float, bytearray, int]] = {}
    pdus = []
    for rec in records:
        if rec.type not in (PKT_ACL_SENT, PKT_ACL_RECV) or len(rec.payload) < 4:
            continue
        direction = "tx" if rec.type == PKT_ACL_SENT else "rx"
        hdr, dlen = struct.unpack_from("<HH", rec.payload, 0)
        conn = hdr & 0x0FFF
        pb = (hdr >> 12) & 0x3
        frag = rec.payload[4: 4 + dlen]
        key = (direction, conn)

        if pb == 0x1:  # continuation
            if key not in pending:
                continue
            ts, buf, need = pending[key]
            buf += frag
        else:  # 0x0 / 0x2: start of an L2CAP frame
            if len(frag) < 4:
                continue
            (need,) = struct.unpack_from("<H", frag, 0)
            ts, buf = rec.ts, bytearray(frag)
        if len(buf) < 4 + need:
            pending[key] = (ts, buf, need)
            continue
        pending.pop(key, None)

        l2len, cid = struct.unpack_from("<HH", buf, 0)
        if cid != ATT_CID:
            continue
        att = bytes(buf[4: 4 + l2len])
        if not att:
            continue
        opcode = att[0]
        handle, value = None, att[1:]
        if opcode in HANDLE_VALUE_OPS and len(att) >= 3:
            (handle,) = struct.unpack_from("<H", att, 1)
            value = att[3:]
        elif opcode == 0x0A and len(att) >= 3:
            (handle,) = struct.unpack_from("<H", att, 1)
            value = b""
        pdus.append(AttPdu(ts, direction, conn, opcode, handle, value))
    return pdus


def split_jobs(pdus: list[AttPdu], gap: float) -> list[list[AttPdu]]:
    """Split on idle periods (no ATT traffic for `gap` seconds)."""
    jobs: list[list[AttPdu]] = []
    last = None
    for p in pdus:
        if last is None or p.ts - last > gap:
            jobs.append([])
        jobs[-1].append(p)
        last = p.ts
    return jobs


def handle_names(gatt_json: Path | None) -> dict[int, str]:
    """Map ATT value handles to characteristic UUIDs from ble_recon output.

    bleak/CoreBluetooth reports the characteristic *declaration* handle; the value
    handle is declaration + 1, and the CCCD follows. Verify against the capture.
    """
    names: dict[int, str] = {}
    if not gatt_json or not gatt_json.exists():
        return names
    report = json.loads(gatt_json.read_text())
    for dev in report.get("devices", []):
        for svc in dev["services"]:
            for ch in svc["characteristics"]:
                uuid = ch["uuid"].lower()
                # SIG-base UUIDs -> 16-bit form; vendor UUIDs -> first two groups,
                # since the ISSC characteristics all share the 49535343 prefix.
                short = (uuid[4:8] if uuid.endswith("-0000-1000-8000-00805f9b34fb")
                         else "-".join(uuid.split("-")[:2]))
                names[ch["handle"] + 1] = f"{short} value"
                for d in ch["descriptors"]:
                    if d["uuid"].startswith("00002902"):
                        names[d["handle"]] = f"{short} CCCD"
    return names


def preview(b: bytes, limit: int = 160) -> str:
    s = "".join(chr(c) if 32 <= c < 127 else ("\\n" if c == 10 else ("\\r" if c == 13 else "."))
                for c in b[:limit])
    return s + ("…" if len(b) > limit else "")


def summarize(jobs: list[list[AttPdu]], names: dict[int, str], out: Path | None) -> None:
    t0 = jobs[0][0].ts if jobs and jobs[0] else 0.0
    for i, job in enumerate(jobs, 1):
        dur = job[-1].ts - job[0].ts
        print(f"\n=== job {i}: t+{job[0].ts - t0:.3f}s, {dur:.3f}s, {len(job)} ATT PDUs")
        ops = defaultdict(int)
        streams: dict[tuple[str, str, int | None], bytearray] = defaultdict(bytearray)
        sizes: dict[tuple[str, str, int | None], list[int]] = defaultdict(list)
        for p in job:
            ops[(p.direction, p.op_name)] += 1
            if p.handle is not None and p.opcode in HANDLE_VALUE_OPS:
                k = (p.direction, p.op_name, p.handle)
                streams[k] += p.value
                sizes[k].append(len(p.value))
            elif p.opcode in (0x02, 0x03):
                print(f"  {p.direction} {p.op_name} mtu={int.from_bytes(p.value[:2], 'little')}")
            elif p.opcode == 0x01:
                print(f"  {p.direction} ERROR_RSP {p.value.hex()}")
        print("  ops:", ", ".join(f"{d}:{o}x{n}" for (d, o), n in sorted(ops.items())))
        for (d, op, h), data in sorted(streams.items(), key=lambda kv: kv[0][2] or 0):
            sz = sizes[(d, op, h)]
            label = names.get(h, "?")
            print(f"  {d} {op} handle=0x{h:04X} ({label}): {len(sz)} PDUs, {len(data)} bytes, "
                  f"sizes min/max {min(sz)}/{max(sz)}")
            print(f"    head: {preview(bytes(data))}")
            if len(data) > 160:
                print(f"    tail: {preview(bytes(data[-80:]), 80)}")
            if out:
                out.mkdir(parents=True, exist_ok=True)
                (out / f"job{i:02d}_{d}_{op}_h{h:04X}.bin").write_bytes(bytes(data))
        if len(job) > 1:
            tx = [p.ts for p in job if p.direction == "tx" and p.opcode in (0x12, 0x52)]
            if len(tx) > 1:
                deltas = sorted(b - a for a, b in zip(tx, tx[1:]))
                print(f"  tx write spacing: median {deltas[len(deltas) // 2] * 1000:.1f} ms, "
                      f"max {deltas[-1] * 1000:.1f} ms")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pklg", type=Path)
    ap.add_argument("--gatt", type=Path, default=Path("tests/golden/gatt-recon.json"))
    ap.add_argument("--gap", type=float, default=3.0, help="idle seconds that separate jobs")
    ap.add_argument("--out", type=Path, help="directory for per-stream .bin files")
    args = ap.parse_args()

    records = read_records(args.pklg.read_bytes())
    pdus = reassemble_att(records)
    print(f"{len(records)} records, {len(pdus)} ATT PDUs")
    if not pdus:
        print("No ATT traffic found. Was the trace running during the print, and is the "
              "Bluetooth logging profile needed for payloads?")
        return 1
    summarize(split_jobs(pdus, args.gap), handle_names(args.gatt), args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
