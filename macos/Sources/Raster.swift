// PDF -> 800x1200 1-bit label raster. Port of src/y813/raster.py (same policy, see docs/pdf-mapping.md).

import CoreGraphics
import Foundation

/// 1 byte per pixel, 1 = black. Row 0 is the top of the label.
struct Bitmap {
    let width: Int
    let height: Int
    var px: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        px = [UInt8](repeating: 0, count: width * height)
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { px[y * width + x] }
        set { px[y * width + x] = newValue }
    }

    /// Clockwise quarter turn (landscape page -> portrait label).
    func rotatedClockwise() -> Bitmap {
        var out = Bitmap(width: height, height: width)
        for y in 0..<height { for x in 0..<width { out[height - 1 - y, x] = self[x, y] } }
        return out
    }

    /// PBM P4: MSB-first, 1 = black, which is exactly the Y813 BITMAP bit layout.
    func packedRows() -> Data {
        let wb = (width + 7) / 8
        var out = Data(count: wb * height)
        out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width where px[y * width + x] != 0 {
                    o[y * wb + x / 8] |= UInt8(0x80 >> (x % 8))
                }
            }
        }
        return out
    }

    func pbm() -> Data { Data("P4\n\(width) \(height)\n".utf8) + packedRows() }

    static func fromPBM(_ data: Data) throws -> Bitmap {
        // Header: "P4" whitespace width whitespace height single-whitespace, then packed rows.
        var fields: [String] = []
        var i = data.startIndex
        while fields.count < 3 {
            while i < data.endIndex, " \n\r\t".utf8.contains(data[i]) { i += 1 }
            if i < data.endIndex, data[i] == UInt8(ascii: "#") {
                while i < data.endIndex, data[i] != 10 { i += 1 }
                continue
            }
            var tok = ""
            while i < data.endIndex, !" \n\r\t".utf8.contains(data[i]) { tok.append(Character(UnicodeScalar(data[i]))); i += 1 }
            fields.append(tok)
        }
        i += 1
        guard fields[0] == "P4", let w = Int(fields[1]), let h = Int(fields[2]) else {
            throw NSError(domain: "PBM", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a P4 PBM"])
        }
        let wb = (w + 7) / 8
        let rows = [UInt8](data[i...])
        guard rows.count >= wb * h else { throw NSError(domain: "PBM", code: 2) }
        var bm = Bitmap(width: w, height: h)
        for y in 0..<h { for x in 0..<w where rows[y * wb + x / 8] & UInt8(0x80 >> (x % 8)) != 0 { bm[x, y] = 1 } }
        return bm
    }
}

struct ClipReport {
    var left = 0, right = 0, top = 0, bottom = 0
    var ruleLinesDropped = 0
    var total: Int { left + right + top + bottom }
}

struct RasterResult {
    let image: Bitmap
    let scale: Double
    let rotated: Bool
    let clip: ClipReport
    let pageSizePt: CGSize
}

enum RasterError: Error, CustomStringConvertible {
    case unreadable, noPage(Int), pageSize(CGSize)
    var description: String {
        switch self {
        case .unreadable: return "not a readable PDF"
        case .noPage(let n): return "PDF has no page \(n)"
        case .pageSize(let s):
            return String(format: "page is %.2f x %.2f in; expected a 4x6 in (or 100x150 mm) label page", s.width / 72, s.height / 72)
        }
    }
}

enum Raster {
    static let dotsPerMM = 8.0
    static let ptPerMM = 72.0 / 25.4
    static let labelWmm = 100, labelHmm = 150
    static let acceptedPagesPt: [CGSize] = [CGSize(width: 288, height: 432),
                                            CGSize(width: 100 * ptPerMM, height: 150 * ptPerMM)]
    static let tolerance = 0.02

    static func isLandscape(_ s: CGSize) throws -> Bool {
        for p in acceptedPagesPt {
            for (a, b, rot) in [(s.width, s.height, false), (s.height, s.width, true)]
            where abs(a - p.width) / p.width <= tolerance && abs(b - p.height) / p.height <= tolerance {
                return rot
            }
        }
        throw RasterError.pageSize(s)
    }

    /// Render one page at 8 dots/mm x scale, thresholded at 50 %, as a portrait bitmap.
    static func render(_ page: CGPDFPage, scale: Double) throws -> (Bitmap, Bool, CGSize) {
        let box = page.getBoxRect(.cropBox)
        let rot = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size
        let landscape = try isLandscape(size)

        let k = dotsPerMM / ptPerMM * scale
        let w = Int((size.width * k).rounded()), h = Int((size.height * k).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw RasterError.unreadable }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: k, y: k)
        // Apply /Rotate (clockwise on display) so the bitmap shows the page as a viewer would.
        switch rot {
        case 90: ctx.translateBy(x: 0, y: box.width); ctx.rotate(by: -.pi / 2)
        case 180: ctx.translateBy(x: box.width, y: box.height); ctx.rotate(by: .pi)
        case 270: ctx.translateBy(x: box.height, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.clip(to: box)
        ctx.drawPDFPage(page)

        guard let data = ctx.data else { throw RasterError.unreadable }
        let gray = data.bindMemory(to: UInt8.self, capacity: w * h)
        var bm = Bitmap(width: w, height: h)
        for i in 0..<(w * h) where gray[i] < 128 { bm.px[i] = 1 }
        if landscape { bm = bm.rotatedClockwise() }
        return (bm, landscape, size)
    }

    /// Python-style floor division (offsets go negative when the page is smaller than the label).
    static func floorDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.down)) }

    /// Ink outside the window [x0, x0+cw) x [y0, y0+ch), ignoring rows/cols that are >= 90 % ink
    /// over the whole page (frame and rule lines).
    static func clipReport(_ p: Bitmap, x0: Int, y0: Int, cw: Int, ch: Int) -> ClipReport {
        var rowInk = [Int](repeating: 0, count: p.height), colInk = [Int](repeating: 0, count: p.width)
        for y in 0..<p.height { for x in 0..<p.width where p[x, y] != 0 { rowInk[y] += 1; colInk[x] += 1 } }
        let ruleRow = rowInk.map { Double($0) >= 0.9 * Double(p.width) }
        let ruleCol = colInk.map { Double($0) >= 0.9 * Double(p.height) }
        var r = ClipReport()
        for y in 0..<p.height where !ruleRow[y] {
            for x in 0..<p.width where p[x, y] != 0 && !ruleCol[x] {
                if x < x0 { r.left += 1 } else if x >= x0 + cw { r.right += 1 }
                else if y < y0 { r.top += 1 } else if y >= y0 + ch { r.bottom += 1 }
            }
        }
        r.ruleLinesDropped = (0..<p.height).filter { ruleRow[$0] && ($0 < y0 || $0 >= y0 + ch) }.count
            + (0..<p.width).filter { ruleCol[$0] && ($0 < x0 || $0 >= x0 + cw) }.count
        return r
    }

    enum Fit: String { case auto, crop, shrink }

    static func pdfToLabel(_ pdf: CGPDFDocument, fit: Fit = .auto, maxClipDots: Int = 50, pageIndex: Int = 0) throws -> RasterResult {
        guard let page = pdf.page(at: pageIndex + 1) else { throw RasterError.noPage(pageIndex + 1) }
        let cw = labelWmm * Int(dotsPerMM), ch = labelHmm * Int(dotsPerMM)

        var (img, rotated, size) = try render(page, scale: 1)
        var scale = 1.0
        var x0 = floorDiv(img.width - cw, 2), y0 = floorDiv(img.height - ch, 2)
        var clip = (x0 > 0 || y0 > 0) ? clipReport(img, x0: x0, y0: y0, cw: cw, ch: ch) : ClipReport()

        if fit == .shrink || (fit == .auto && clip.total > maxClipDots) {
            scale = min(Double(cw) / Double(img.width), Double(ch) / Double(img.height), 1)
            if scale < 1 {
                (img, rotated, size) = try render(page, scale: scale)
                x0 = floorDiv(img.width - cw, 2); y0 = floorDiv(img.height - ch, 2)
                clip = (x0 > 0 || y0 > 0) ? clipReport(img, x0: x0, y0: y0, cw: cw, ch: ch) : ClipReport()
            }
        }

        var canvas = Bitmap(width: cw, height: ch)
        for y in 0..<ch {
            let sy = y + y0
            guard sy >= 0, sy < img.height else { continue }
            for x in 0..<cw {
                let sx = x + x0
                if sx >= 0, sx < img.width, img[sx, sy] != 0 { canvas[x, y] = 1 }
            }
        }
        return RasterResult(image: canvas, scale: scale, rotated: rotated, clip: clip, pageSizePt: size)
    }
}
