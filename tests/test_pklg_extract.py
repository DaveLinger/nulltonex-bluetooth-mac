"""Synthetic-capture tests for scripts/pklg_extract.py.

Run: .venv/bin/python -m unittest discover -s tests
"""

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import pklg_extract as px  # noqa: E402

CONN = 0x0040


def record(ts: float, rtype: int, payload: bytes, endian: str = ">") -> bytes:
    secs, usecs = int(ts), round((ts - int(ts)) * 1e6)
    return struct.pack(endian + "III", 9 + len(payload), secs, usecs) + bytes([rtype]) + payload


def acl(att: bytes, frag_size: int = 1000) -> list[bytes]:
    """Wrap an ATT PDU in L2CAP and split into HCI ACL fragments."""
    l2 = struct.pack("<HH", len(att), px.ATT_CID) + att
    out = []
    for i in range(0, len(l2), frag_size):
        pb = 0x2 if i == 0 else 0x1
        chunk = l2[i: i + frag_size]
        out.append(struct.pack("<HH", CONN | (pb << 12), len(chunk)) + chunk)
    return out


def capture(endian: str = ">") -> bytes:
    data = b""
    t = 1000.0

    def add(rtype, att, frag_size=1000):
        nonlocal data, t
        for frag in acl(att, frag_size):
            data += record(t, rtype, frag, endian)
        t += 0.01

    # An HCI event that must be ignored.
    data += record(t, px.PKT_HCI_EVENT, b"\x0e\x04\x01\x03\x0c\x00", endian)
    add(px.PKT_ACL_SENT, b"\x02" + struct.pack("<H", 247))
    add(px.PKT_ACL_RECV, b"\x03" + struct.pack("<H", 247))
    # Job 1: TSPL header + 244-byte bitmap chunk fragmented at 27 bytes (LE default).
    add(px.PKT_ACL_SENT, b"\x52" + struct.pack("<H", 0x0D) + b"SIZE 40 mm,30 mm\r\n")
    add(px.PKT_ACL_SENT, b"\x52" + struct.pack("<H", 0x0D) + bytes([0xFF]) * 244, frag_size=27)
    add(px.PKT_ACL_SENT, b"\x52" + struct.pack("<H", 0x0D) + b"PRINT 1,1\r\n")
    add(px.PKT_ACL_RECV, b"\x1b" + struct.pack("<H", 0x0A) + b"OK")
    # Job 2 after an idle gap.
    t += 5.0
    add(px.PKT_ACL_SENT, b"\x12" + struct.pack("<H", 0x19) + b"CLS\r\n")
    add(px.PKT_ACL_RECV, b"\x13")
    return data


class PklgTests(unittest.TestCase):
    def check(self, endian: str) -> None:
        recs = px.read_records(capture(endian))
        pdus = px.reassemble_att(recs)
        self.assertEqual([p.op_name for p in pdus],
                         ["MTU_REQ", "MTU_RSP", "WRITE_CMD", "WRITE_CMD", "WRITE_CMD",
                          "NOTIFY", "WRITE_REQ", "WRITE_RSP"])
        big = pdus[3]
        self.assertEqual((big.direction, big.handle, len(big.value)), ("tx", 0x0D, 244))
        self.assertEqual(pdus[5].value, b"OK")

        jobs = px.split_jobs(pdus, gap=3.0)
        self.assertEqual([len(j) for j in jobs], [6, 2])
        stream = b"".join(p.value for p in jobs[0] if p.handle == 0x0D)
        self.assertTrue(stream.startswith(b"SIZE 40 mm,30 mm\r\n"))
        self.assertTrue(stream.endswith(b"PRINT 1,1\r\n"))

    def test_big_endian(self):
        self.check(">")

    def test_little_endian(self):
        self.check("<")

    def test_handle_names_use_value_handle(self):
        names = px.handle_names(Path(__file__).resolve().parent / "golden" / "gatt-recon.json")
        self.assertEqual(names[13], "49535343-8841 value")   # ISSC write char, decl 12
        self.assertEqual(names[22], "2af0 value")
        self.assertEqual(names[25], "bef8d6c9-9c21 value")
        self.assertEqual(names[26], "bef8d6c9-9c21 CCCD")


if __name__ == "__main__":
    unittest.main()
