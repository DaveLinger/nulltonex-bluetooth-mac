// IPP Everywhere-style printer object: attributes, job table, and the serial print worker.

import CoreGraphics
import Foundation

final class Job {
    let id: Int32
    let name: String
    let user: String
    let quality: Int32            // IPP print-quality: 3 draft, 4 normal, 5 high
    let created = Date()
    var state: Int32 = 3          // 3 pending, 5 processing, 7 canceled, 8 aborted, 9 completed
    var reasons = ["none"]
    var message = ""
    var processed: Date?
    var completed: Date?
    var document: Data?

    init(id: Int32, name: String, user: String, quality: Int32, document: Data) {
        self.id = id
        self.name = name
        self.user = user
        self.quality = quality
        self.document = document
    }
}

final class PrinterService {
    let port: UInt16
    /// DENSITY for print-quality normal; draft/high are 3 steps either side (Pixmate Light/Medium/Dark = 8/11/14).
    let density: Int
    private let uri: String
    private let start = Date()
    private let lock = NSLock()
    private var jobs: [Int32: Job] = [:]
    private var nextID: Int32 = 1
    private var printerState: Int32 = 3   // 3 idle, 4 processing
    private var printerReasons = ["none"]
    private let worker = DispatchQueue(label: "y813.jobs")
    private let link = Y813Link()
    private let log: (String) -> Void

    static let medias: [(keyword: String, x: Int32, y: Int32)] = [
        ("na_index-4x6_4x6in", 10160, 15240),
        ("om_small-photo_100x150mm", 10000, 15000),
    ]

    init(port: UInt16, density: Int, log: @escaping (String) -> Void) {
        self.port = port
        self.density = density
        self.log = log
        uri = "ipp://127.0.0.1:\(port)/ipp/print"
        link.prepare()
    }

    func density(forQuality q: Int32) -> Int {
        let offset = q == 3 ? -3 : q == 5 ? 3 : 0
        return min(max(density + offset, 0), 15)
    }

    // MARK: HTTP entry

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard req.method == "POST" else {
            return HTTPResponse(contentType: "text/plain", body: Data("Y813 Print Service: \(uri)\n".utf8))
        }
        guard let ipp = try? IPPRequest.parse(req.body) else {
            return HTTPResponse(status: 400, reason: "Bad Request", contentType: "text/plain")
        }
        return HTTPResponse(body: respond(ipp))
    }

    private func respond(_ r: IPPRequest) -> Data {
        let major = min(r.major, 2)
        func reply(_ status: UInt16, _ message: String? = nil) -> IPPWriter {
            var w = IPPWriter(major: major, minor: major == 2 ? 0 : 1, status: status, requestID: r.requestID)
            if let message { w.attr("status-message", [.text(message)]) }
            return w
        }

        switch r.operation {
        case IPPOp.getPrinterAttributes:
            var w = reply(IPPStatus.ok)
            w.group(IPPTag.printerGroup)
            for (n, v) in printerAttributes() { w.attr(n, v) }
            return w.finish()

        case IPPOp.validateJob:
            if let err = formatError(r) { return reply(IPPStatus.documentFormatNotSupported, err).finish() }
            return reply(IPPStatus.ok).finish()

        case IPPOp.printJob:
            if let err = formatError(r) { return reply(IPPStatus.documentFormatNotSupported, err).finish() }
            guard r.document.starts(with: Data("%PDF".utf8)) else {
                return reply(IPPStatus.documentFormatNotSupported, "document is not a PDF").finish()
            }
            let job = enqueue(r)
            var w = reply(IPPStatus.ok)
            w.group(IPPTag.jobGroup)
            for (n, v) in jobAttributes(job) { w.attr(n, v) }
            return w.finish()

        case IPPOp.getJobAttributes:
            guard let job = findJob(r) else { return reply(IPPStatus.notFound, "job not found").finish() }
            var w = reply(IPPStatus.ok)
            w.group(IPPTag.jobGroup)
            for (n, v) in jobAttributes(job) { w.attr(n, v) }
            return w.finish()

        case IPPOp.getJobs:
            let which = r.op("which-jobs")?.string ?? "not-completed"
            let limit = Int(r.op("limit")?.int ?? 1000)
            lock.lock()
            let list = jobs.values.filter { which == "completed" ? $0.state >= 7 : which == "all" || $0.state < 7 }
                .sorted { $0.id > $1.id }.prefix(limit)
            lock.unlock()
            var w = reply(IPPStatus.ok)
            for job in list {
                w.group(IPPTag.jobGroup)
                for (n, v) in jobAttributes(job) { w.attr(n, v) }
            }
            return w.finish()

        case IPPOp.cancelJob:
            guard let job = findJob(r) else { return reply(IPPStatus.notFound, "job not found").finish() }
            lock.lock()
            defer { lock.unlock() }
            guard job.state == 3 else { return reply(IPPStatus.notPossible, "job is not pending").finish() }
            job.state = 7
            job.reasons = ["job-canceled-by-user"]
            job.completed = Date()
            job.document = nil
            return reply(IPPStatus.ok).finish()

        default:
            return reply(IPPStatus.operationNotSupported).finish()
        }
    }

    private func formatError(_ r: IPPRequest) -> String? {
        guard let f = r.op("document-format")?.string, !f.isEmpty else { return nil }
        return ["application/pdf", "application/octet-stream"].contains(f) ? nil : "unsupported document-format \(f)"
    }

    private func findJob(_ r: IPPRequest) -> Job? {
        var id = r.op("job-id")?.int
        if id == nil, let u = r.op("job-uri")?.string, let last = u.split(separator: "/").last { id = Int32(last) }
        lock.lock(); defer { lock.unlock() }
        return id.flatMap { jobs[$0] }
    }

    // MARK: Jobs

    private func enqueue(_ r: IPPRequest) -> Job {
        // print-quality is a job template attribute (job group), but accept it in the operation group too.
        let q = (r.groups[IPPTag.jobGroup]?["print-quality"]?.first ?? r.op("print-quality"))?.int ?? 4
        let quality: Int32 = (3...5).contains(q) ? q : 4
        lock.lock()
        let job = Job(id: nextID, name: r.op("job-name")?.string ?? "Untitled",
                      user: r.op("requesting-user-name")?.string ?? "anonymous", quality: quality, document: r.document)
        nextID += 1
        jobs[job.id] = job
        // Keep the table small: drop finished jobs beyond the last 50.
        let finished = jobs.values.filter { $0.state >= 7 }.sorted { $0.id < $1.id }
        for old in finished.dropLast(50) { jobs[old.id] = nil }
        lock.unlock()
        log("job \(job.id) received: \(r.document.count) bytes, print-quality \(quality) -> DENSITY \(density(forQuality: quality))")
        worker.async { self.process(job) }
        return job
    }

    private func setJob(_ job: Job, _ body: (Job) -> Void) { lock.lock(); body(job); lock.unlock() }

    private func process(_ job: Job) {
        lock.lock()
        guard job.state == 3, let pdfData = job.document else { lock.unlock(); return }
        job.state = 5
        job.reasons = ["job-printing"]
        job.processed = Date()
        printerState = 4
        lock.unlock()

        var finalState: Int32 = 9
        var reasons = ["job-completed-successfully"]
        var printerR = ["none"]
        do {
            guard let provider = CGDataProvider(data: pdfData as CFData), let pdf = CGPDFDocument(provider) else {
                throw RasterError.unreadable
            }
            if pdf.numberOfPages > 1 { log("job \(job.id): \(pdf.numberOfPages) pages; printing all") }
            for page in 0..<pdf.numberOfPages {
                let r = try Raster.pdfToLabel(pdf, pageIndex: page)
                log(String(format: "job %d page %d: scale %.1f%%%@, cut L%d R%d T%d B%d", job.id, page + 1, r.scale * 100,
                           r.rotated ? " (rotated)" : "", r.clip.left, r.clip.right, r.clip.top, r.clip.bottom))
                let tspl = TSPL.encodeJob(r.image, widthMM: Raster.labelWmm, heightMM: Raster.labelHmm,
                                          density: density(forQuality: job.quality))
                let status = try sendWithRetry(tspl, job: job)
                if let s = status, !PrinterStatus.reasons(s).isEmpty {
                    printerR = PrinterStatus.reasons(s).map { $0 + "-error" }
                    throw NSError(domain: "Y813", code: Int(s), userInfo: [NSLocalizedDescriptionKey:
                        String(format: "printer status 0x%02X: %@", s, PrinterStatus.reasons(s).joined(separator: ", "))])
                }
                log("job \(job.id) page \(page + 1): status \(status.map { String(format: "0x%02X", $0) } ?? "none")")
            }
        } catch {
            finalState = 8
            reasons = ["aborted-by-system"]
            if case BLEError.notFound = error { printerR = ["offline-report"] }
            setJob(job) { $0.message = "\(error)" }
            log("job \(job.id) aborted: \(error)")
        }
        lock.lock()
        job.state = finalState
        job.reasons = reasons
        job.completed = Date()
        job.document = nil
        printerState = 3
        printerReasons = printerR
        lock.unlock()
    }

    private func sendWithRetry(_ tspl: Data, job: Job) throws -> UInt8? {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try link.send(tspl) { self.log("job \(job.id): \($0)") }
            } catch let e as BLEError {
                switch e {
                case .unauthorized, .missingCharacteristic, .duringTransfer: throw e
                default:
                    // Everything else failed before any data was written, so a retry can't double-print.
                    guard attempt < 3 else { throw e }
                    log("job \(job.id): \(e); retrying in 5 s")
                    Thread.sleep(forTimeInterval: 5)
                }
            }
        }
    }

    // MARK: Attributes

    private func mediaCol(_ m: (keyword: String, x: Int32, y: Int32)) -> IPPValue {
        .collection([
            ("media-size", [.collection([("x-dimension", [.integer(m.x)]), ("y-dimension", [.integer(m.y)])])]),
            ("media-size-name", [.keyword(m.keyword)]),
            ("media-top-margin", [.integer(0)]), ("media-bottom-margin", [.integer(0)]),
            ("media-left-margin", [.integer(0)]), ("media-right-margin", [.integer(0)]),
            ("media-source", [.keyword("main")]), ("media-type", [.keyword("labels")]),
        ])
    }

    private func printerAttributes() -> [(String, [IPPValue])] {
        lock.lock()
        let state = printerState, reasons = printerReasons
        let queued = Int32(jobs.values.filter { $0.state < 7 }.count)
        lock.unlock()
        let ops = [IPPOp.printJob, IPPOp.validateJob, IPPOp.cancelJob, IPPOp.getJobAttributes, IPPOp.getJobs,
                   IPPOp.getPrinterAttributes].map { IPPValue.enumValue(Int32($0)) }
        return [
            ("printer-uri-supported", [.uri(uri)]),
            ("uri-security-supported", [.keyword("none")]),
            ("uri-authentication-supported", [.keyword("none")]),
            ("printer-name", [.name("Y813")]),
            ("printer-info", [.text("NULLTONEX Y813 (BLE)")]),
            ("printer-location", [.text("Bluetooth LE")]),
            ("printer-more-info", [.uri("http://127.0.0.1:\(port)/")]),
            ("printer-make-and-model", [.text("NULLTONEX Y813")]),
            ("printer-device-id", [.text("MFG:NULLTONEX;MDL:Y813;CMD:PDF;CLS:PRINTER;")]),
            ("printer-uuid", [.uri("urn:uuid:7d1c0a7e-8b13-4d1e-9f3a-5e0f2c813000")]),
            ("printer-state", [.enumValue(state)]),
            ("printer-state-reasons", reasons.map { .keyword($0) }),
            ("printer-is-accepting-jobs", [.boolean(true)]),
            ("printer-up-time", [.integer(Int32(Date().timeIntervalSince(start)))]),
            ("queued-job-count", [.integer(queued)]),
            ("ipp-versions-supported", [.keyword("1.1"), .keyword("2.0")]),
            ("operations-supported", ops),
            ("charset-configured", [.charset("utf-8")]),
            ("charset-supported", [.charset("utf-8")]),
            ("natural-language-configured", [.language("en")]),
            ("generated-natural-language-supported", [.language("en")]),
            ("document-format-default", [.mime("application/pdf")]),
            ("document-format-supported", [.mime("application/pdf"), .mime("application/octet-stream")]),
            ("pdl-override-supported", [.keyword("attempted")]),
            ("compression-supported", [.keyword("none")]),
            ("color-supported", [.boolean(false)]),
            ("print-color-mode-default", [.keyword("monochrome")]),
            ("print-color-mode-supported", [.keyword("monochrome")]),
            ("printer-resolution-default", [.resolution(203, 203)]),
            ("printer-resolution-supported", [.resolution(203, 203)]),
            ("print-quality-default", [.enumValue(4)]),
            ("print-quality-supported", [.enumValue(3), .enumValue(4), .enumValue(5)]),
            ("sides-default", [.keyword("one-sided")]),
            ("sides-supported", [.keyword("one-sided")]),
            ("copies-default", [.integer(1)]),
            ("copies-supported", [.range(1, 1)]),
            ("orientation-requested-default", [.enumValue(3)]),
            ("orientation-requested-supported", [.enumValue(3)]),
            ("job-creation-attributes-supported", [.keyword("media"), .keyword("media-col"), .keyword("copies"),
                                                   .keyword("print-quality")]),
            ("media-default", [.keyword(Self.medias[0].keyword)]),
            ("media-supported", Self.medias.map { .keyword($0.keyword) }),
            ("media-ready", Self.medias.map { .keyword($0.keyword) }),
            ("media-col-default", [mediaCol(Self.medias[0])]),
            ("media-col-ready", Self.medias.map { mediaCol($0) }),
            ("media-col-database", Self.medias.map { mediaCol($0) }),
            ("media-col-supported", ["media-size", "media-top-margin", "media-bottom-margin", "media-left-margin",
                                     "media-right-margin", "media-source", "media-type"].map { .keyword($0) }),
            ("media-size-supported", Self.medias.map {
                .collection([("x-dimension", [.integer($0.x)]), ("y-dimension", [.integer($0.y)])])
            }),
            ("media-top-margin-supported", [.integer(0)]),
            ("media-bottom-margin-supported", [.integer(0)]),
            ("media-left-margin-supported", [.integer(0)]),
            ("media-right-margin-supported", [.integer(0)]),
            ("media-source-supported", [.keyword("main")]),
            ("media-type-supported", [.keyword("labels")]),
            ("printer-kind", [.keyword("labels")]),
            ("multiple-document-handling-supported", [.keyword("separate-documents-uncollated-copies")]),
            ("which-jobs-supported", [.keyword("completed"), .keyword("not-completed"), .keyword("all")]),
        ]
    }

    private func jobAttributes(_ job: Job) -> [(String, [IPPValue])] {
        lock.lock(); defer { lock.unlock() }
        let up: (Date?) -> IPPValue = { d in d.map { .integer(Int32($0.timeIntervalSince(self.start))) } ?? .noValue }
        var a: [(String, [IPPValue])] = [
            ("job-id", [.integer(job.id)]),
            ("job-uri", [.uri("\(uri)/\(job.id)")]),
            ("job-printer-uri", [.uri(uri)]),
            ("job-name", [.name(job.name)]),
            ("job-originating-user-name", [.name(job.user)]),
            ("job-state", [.enumValue(job.state)]),
            ("job-state-reasons", job.reasons.map { .keyword($0) }),
            ("print-quality", [.enumValue(job.quality)]),
            ("time-at-creation", [up(job.created)]),
            ("time-at-processing", [up(job.processed)]),
            ("time-at-completed", [up(job.completed)]),
            ("job-printer-up-time", [.integer(Int32(Date().timeIntervalSince(start)))]),
        ]
        if !job.message.isEmpty { a.append(("job-state-message", [.text(job.message)])) }
        return a
    }
}
