// TSPL job encoder. Port of src/y813/tspl.py; must stay byte-identical (tests/test_swift_port.py).

import Foundation

enum TSPL {
    static let bandRows = 188
    static let statusQuery = Data([0x1B, 0x21, 0x3F])  // ESC ! ?

    static func zlibCompress(_ input: Data) -> Data {
        var destLen = compressBound(uLong(input.count))
        var out = Data(count: Int(destLen))
        let rc = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                compress2(o.bindMemory(to: Bytef.self).baseAddress, &destLen,
                          i.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        precondition(rc == Z_OK, "zlib compress2 failed: \(rc)")
        return out.prefix(Int(destLen))
    }

    static func encodeJob(_ img: Bitmap, widthMM: Int, heightMM: Int, density: Int = 11, gapMM: Int = 2, copies: Int = 1) -> Data {
        precondition((0...15).contains(density), "density must be 0-15")
        precondition(img.width % 8 == 0 && img.width <= widthMM * 8 && img.height <= heightMM * 8)
        let wb = img.width / 8
        let raster = img.packedRows()

        var out = Data("CLS\r\nDENSITY \(density)\r\n".utf8)
        let header: [String] = ["SIZE \(widthMM) mm,\(heightMM) mm", "GAP \(gapMM) mm,0 mm", "REFERENCE 0,0",
                                "SET TEAR ON", "SET RESPONSE ON", "CLS"]
        out += Data(header.map { $0 + "\r\n" }.joined().utf8)
        var y = 0
        while y < img.height {
            let rows = min(bandRows, img.height - y)
            let comp = zlibCompress(raster.subdata(in: (y * wb)..<((y + rows) * wb)))
            out += Data("BITMAP 0,\(y),\(wb),\(rows),3,\(comp.count),".utf8) + comp
            y += rows
        }
        out += Data("PRINT 1,\(copies)\r\n".utf8) + statusQuery
        return out
    }

    /// First write = leading "CLS/DENSITY" lines (Pixmate pauses after it); rest in 244-byte chunks.
    static func planWrites(_ job: Data, chunk: Int = 244) -> [Data] {
        var writes: [Data] = []
        var rest = job[...]
        if let d = job.prefix(32).range(of: Data("DENSITY".utf8)),
           let nl = job.range(of: Data("\r\n".utf8), in: d.upperBound..<job.endIndex) {
            writes.append(Data(job[..<nl.upperBound]))
            rest = job[nl.upperBound...]
        }
        var i = rest.startIndex
        while i < rest.endIndex {
            let j = min(i + chunk, rest.endIndex)
            writes.append(Data(rest[i..<j]))
            i = j
        }
        return writes
    }
}
