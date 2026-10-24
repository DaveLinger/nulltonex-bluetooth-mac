// Minimal IPP/1.1-2.0 message codec (RFC 8010): enough for a local IPP Everywhere printer.

import Foundation

enum IPPTag {
    static let operationGroup: UInt8 = 0x01
    static let jobGroup: UInt8 = 0x02
    static let endOfAttributes: UInt8 = 0x03
    static let printerGroup: UInt8 = 0x04
    static let unsupportedGroup: UInt8 = 0x05

    static let noValue: UInt8 = 0x13
    static let integer: UInt8 = 0x21
    static let boolean: UInt8 = 0x22
    static let enumValue: UInt8 = 0x23
    static let resolution: UInt8 = 0x32
    static let rangeOfInteger: UInt8 = 0x33
    static let begCollection: UInt8 = 0x34
    static let endCollection: UInt8 = 0x37
    static let text: UInt8 = 0x41
    static let name: UInt8 = 0x42
    static let keyword: UInt8 = 0x44
    static let uri: UInt8 = 0x45
    static let uriScheme: UInt8 = 0x46
    static let charset: UInt8 = 0x47
    static let naturalLanguage: UInt8 = 0x48
    static let mimeMediaType: UInt8 = 0x49
    static let memberAttrName: UInt8 = 0x4A
}

enum IPPOp {
    static let printJob: UInt16 = 0x0002
    static let validateJob: UInt16 = 0x0004
    static let cancelJob: UInt16 = 0x0008
    static let getJobAttributes: UInt16 = 0x0009
    static let getJobs: UInt16 = 0x000A
    static let getPrinterAttributes: UInt16 = 0x000B
}

enum IPPStatus {
    static let ok: UInt16 = 0x0000
    static let badRequest: UInt16 = 0x0400
    static let notPossible: UInt16 = 0x0404
    static let notFound: UInt16 = 0x0406
    static let documentFormatNotSupported: UInt16 = 0x040A
    static let internalError: UInt16 = 0x0500
    static let operationNotSupported: UInt16 = 0x0501
}

struct IPPRawValue {
    let tag: UInt8
    let bytes: Data
    var string: String { String(decoding: bytes, as: UTF8.self) }
    var int: Int32? {
        guard bytes.count == 4 else { return nil }
        return bytes.withUnsafeBytes { Int32(bigEndian: $0.loadUnaligned(as: Int32.self)) }
    }
}

struct IPPRequest {
    var major: UInt8 = 1
    var minor: UInt8 = 1
    var operation: UInt16 = 0
    var requestID: UInt32 = 0
    /// Top-level attributes per group tag (collection members are skipped).
    var groups: [UInt8: [String: [IPPRawValue]]] = [:]
    var document = Data()

    func op(_ name: String) -> IPPRawValue? { groups[IPPTag.operationGroup]?[name]?.first }
    func opAll(_ name: String) -> [IPPRawValue] { groups[IPPTag.operationGroup]?[name] ?? [] }

    enum ParseError: Error { case truncated }

    static func parse(_ data: Data) throws -> IPPRequest {
        let b = [UInt8](data)
        var i = 0
        func u8() throws -> UInt8 { guard i < b.count else { throw ParseError.truncated }; defer { i += 1 }; return b[i] }
        func u16() throws -> Int { Int(try u8()) << 8 | Int(try u8()) }
        func bytes(_ n: Int) throws -> Data {
            guard i + n <= b.count else { throw ParseError.truncated }
            defer { i += n }
            return Data(b[i..<i + n])
        }

        var req = IPPRequest()
        req.major = try u8()
        req.minor = try u8()
        req.operation = UInt16(try u16())
        req.requestID = UInt32(try u16()) << 16 | UInt32(try u16())

        var group: UInt8 = 0
        var lastName = ""
        var depth = 0
        while true {
            let tag = try u8()
            if tag == IPPTag.endOfAttributes { break }
            if tag < 0x10 { group = tag; req.groups[group, default: [:]] = req.groups[group] ?? [:]; continue }
            let nameLen = try u16()
            let name = String(decoding: try bytes(nameLen), as: UTF8.self)
            let valLen = try u16()
            let value = try bytes(valLen)
            if tag == IPPTag.begCollection { depth += 1; continue }
            if tag == IPPTag.endCollection { depth -= 1; continue }
            if depth > 0 { continue }
            if !name.isEmpty { lastName = name }
            req.groups[group, default: [:]][lastName, default: []].append(IPPRawValue(tag: tag, bytes: value))
        }
        req.document = Data(b[i...])
        return req
    }
}

indirect enum IPPValue {
    case keyword(String), text(String), name(String), uri(String), uriScheme(String)
    case charset(String), language(String), mime(String)
    case integer(Int32), enumValue(Int32), boolean(Bool)
    case range(Int32, Int32), resolution(Int32, Int32)
    case collection([(String, [IPPValue])])
    case noValue
}

struct IPPWriter {
    private(set) var data = Data()

    init(major: UInt8, minor: UInt8, status: UInt16, requestID: UInt32) {
        data.append(contentsOf: [major, minor, UInt8(status >> 8), UInt8(status & 0xFF)])
        appendU32(requestID)
        group(IPPTag.operationGroup)
        attr("attributes-charset", [.charset("utf-8")])
        attr("attributes-natural-language", [.language("en")])
    }

    mutating func group(_ tag: UInt8) { data.append(tag) }

    mutating func attr(_ name: String, _ values: [IPPValue]) {
        for (n, v) in values.enumerated() { write(n == 0 ? name : "", v) }
    }

    func finish() -> Data { data + Data([IPPTag.endOfAttributes]) }

    private mutating func appendU16(_ v: Int) { data.append(UInt8((v >> 8) & 0xFF)); data.append(UInt8(v & 0xFF)) }
    private mutating func appendU32(_ v: UInt32) { for s in [24, 16, 8, 0] { data.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    private mutating func appendI32(_ v: Int32) { appendU32(UInt32(bitPattern: v)) }

    private mutating func raw(_ tag: UInt8, _ name: String, _ value: Data) {
        let n = Data(name.utf8)
        data.append(tag); appendU16(n.count); data.append(n)
        appendU16(value.count); data.append(value)
    }

    private func i32(_ v: Int32) -> Data {
        let u = UInt32(bitPattern: v)
        return Data([UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    private mutating func write(_ name: String, _ v: IPPValue) {
        switch v {
        case .keyword(let s): raw(IPPTag.keyword, name, Data(s.utf8))
        case .text(let s): raw(IPPTag.text, name, Data(s.utf8))
        case .name(let s): raw(IPPTag.name, name, Data(s.utf8))
        case .uri(let s): raw(IPPTag.uri, name, Data(s.utf8))
        case .uriScheme(let s): raw(IPPTag.uriScheme, name, Data(s.utf8))
        case .charset(let s): raw(IPPTag.charset, name, Data(s.utf8))
        case .language(let s): raw(IPPTag.naturalLanguage, name, Data(s.utf8))
        case .mime(let s): raw(IPPTag.mimeMediaType, name, Data(s.utf8))
        case .integer(let i): raw(IPPTag.integer, name, i32(i))
        case .enumValue(let i): raw(IPPTag.enumValue, name, i32(i))
        case .boolean(let b): raw(IPPTag.boolean, name, Data([b ? 1 : 0]))
        case .range(let lo, let hi): raw(IPPTag.rangeOfInteger, name, i32(lo) + i32(hi))
        case .resolution(let x, let y): raw(IPPTag.resolution, name, i32(x) + i32(y) + Data([3]))  // 3 = dpi
        case .noValue: raw(IPPTag.noValue, name, Data())
        case .collection(let members):
            raw(IPPTag.begCollection, name, Data())
            for (memberName, values) in members {
                raw(IPPTag.memberAttrName, "", Data(memberName.utf8))
                for mv in values { write("", mv) }
            }
            raw(IPPTag.endCollection, "", Data())
        }
    }
}
