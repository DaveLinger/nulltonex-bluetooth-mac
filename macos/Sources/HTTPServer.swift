// Tiny blocking HTTP/1.1 server on 127.0.0.1 for IPP-over-HTTP (POST application/ipp).
// Handles keep-alive, Content-Length and chunked bodies, and Expect: 100-continue.

import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]  // lowercased names
    let body: Data
}

struct HTTPResponse {
    var status = 200
    var reason = "OK"
    var contentType = "application/ipp"
    var body = Data()
}

final class HTTPServer {
    private let port: UInt16
    private let handler: (HTTPRequest) -> HTTPResponse
    private static let maxBody = 64 << 20

    init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "HTTPServer", code: Int(errno)) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: "HTTPServer", code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "bind/listen 127.0.0.1:\(port): \(String(cString: strerror(err)))"])
        }
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                DispatchQueue.global().async { self.serve(c) }
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let r = SocketReader(fd: fd)

        while true {
            var line: String?
            repeat { line = r.readLine() } while line == ""   // tolerate blank lines between requests
            guard let requestLine = line else { return }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 3 else { return }
            var headers: [String: String] = [:]
            while let h = r.readLine(), !h.isEmpty {
                if let colon = h.firstIndex(of: ":") {
                    headers[h[..<colon].lowercased()] = h[h.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            if headers["expect"]?.lowercased() == "100-continue" {
                guard write(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else { return }
            }
            guard let body = readBody(r, headers) else { return }
            let req = HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
            let resp = handler(req)
            var head = "HTTP/1.1 \(resp.status) \(resp.reason)\r\n"
            head += "Content-Type: \(resp.contentType)\r\nContent-Length: \(resp.body.count)\r\n"
            let close = headers["connection"]?.lowercased() == "close" || parts[2] == "HTTP/1.0"
            head += close ? "Connection: close\r\n\r\n" : "\r\n"
            guard write(fd, Data(head.utf8) + resp.body), !close else { return }
        }
    }

    private func readBody(_ r: SocketReader, _ headers: [String: String]) -> Data? {
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var body = Data()
            while true {
                guard let sizeLine = r.readLine(),
                      let size = Int(sizeLine.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16)
                else { return nil }
                if size == 0 {
                    while let t = r.readLine(), !t.isEmpty {}   // trailers
                    return body
                }
                guard body.count + size <= Self.maxBody, let chunk = r.readExact(size) else { return nil }
                body.append(contentsOf: chunk)
                _ = r.readLine()  // CRLF after chunk
            }
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        guard len <= Self.maxBody else { return nil }
        return len == 0 ? Data() : r.readExact(len).map { Data($0) }
    }

    private func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

final class SocketReader {
    private let fd: Int32
    private var buf: [UInt8] = []
    private var pos = 0

    init(fd: Int32) { self.fd = fd }

    private func fill() -> Bool {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &tmp, tmp.count)
        guard n > 0 else { return false }
        if pos > 0 { buf.removeFirst(pos); pos = 0 }
        buf.append(contentsOf: tmp[0..<n])
        return true
    }

    func readLine() -> String? {
        while true {
            if let nl = buf[pos...].firstIndex(of: 10) {
                var s = String(decoding: buf[pos..<nl], as: UTF8.self)
                pos = nl + 1
                if s.hasSuffix("\r") { s.removeLast() }
                return s
            }
            if buf.count - pos > 16384 || !fill() { return nil }
        }
    }

    func readExact(_ n: Int) -> [UInt8]? {
        while buf.count - pos < n { if !fill() { return nil } }
        defer { pos += n }
        return Array(buf[pos..<pos + n])
    }
}
