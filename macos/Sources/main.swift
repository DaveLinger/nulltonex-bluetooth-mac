// Y813 Print Service: local IPP printer that prints label PDFs to the Y813 over BLE.
//
//   Y813PrintService [serve] [--port 8631] [--density 11]   run the IPP server; density = print-quality normal
//   Y813PrintService render <in.pdf> <out.pbm> [--fit auto|crop|shrink]
//   Y813PrintService encode <in.pbm> <out.bin> --width-mm W --height-mm H [--density N]
//   Y813PrintService print <in.pdf> [--density N]            render + send (needs Bluetooth permission)
//
// Anything touching Bluetooth must run as this app (launchd or `open`), not from a shell
// inside another app, or TCC kills the process.

import AppKit
import CoreGraphics
import Foundation

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Y813PrintService.log")
let logLock = NSLock()

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    logLock.lock()
    defer { logLock.unlock() }
    FileHandle.standardError.write(Data(line.utf8))
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

func fail(_ s: String) -> Never {
    log("error: \(s)")
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let density = Int(option("--density") ?? "11") ?? 11
let port = UInt16(option("--port") ?? "8631") ?? 8631
// LaunchServices may pass -psn_* when launched via `open`.
args.removeAll { $0.hasPrefix("-psn_") }
let command = args.first ?? "serve"

func loadPDF(_ path: String) -> CGPDFDocument {
    guard let pdf = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { fail("cannot read PDF \(path)") }
    return pdf
}

switch command {
case "render":
    guard args.count >= 3 else { fail("usage: render <in.pdf> <out.pbm> [--fit auto|crop|shrink]") }
    let fit = Raster.Fit(rawValue: option("--fit") ?? "auto") ?? .auto
    do {
        let r = try Raster.pdfToLabel(loadPDF(args[1]), fit: fit)
        try r.image.pbm().write(to: URL(fileURLWithPath: args[2]))
        print(String(format: "scale=%.5f rotated=%d clip=%d,%d,%d,%d rules=%d", r.scale, r.rotated ? 1 : 0,
                     r.clip.left, r.clip.right, r.clip.top, r.clip.bottom, r.clip.ruleLinesDropped))
    } catch { fail("\(error)") }

case "encode":
    guard args.count >= 3, let w = Int(option("--width-mm") ?? ""), let h = Int(option("--height-mm") ?? "") else {
        fail("usage: encode <in.pbm> <out.bin> --width-mm W --height-mm H [--density N]")
    }
    do {
        let bm = try Bitmap.fromPBM(Data(contentsOf: URL(fileURLWithPath: args[1])))
        try TSPL.encodeJob(bm, widthMM: w, heightMM: h, density: density).write(to: URL(fileURLWithPath: args[2]))
    } catch { fail("\(error)") }

case "print":
    guard args.count >= 2 else { fail("usage: print <in.pdf>") }
    do {
        let r = try Raster.pdfToLabel(loadPDF(args[1]))
        let job = TSPL.encodeJob(r.image, widthMM: Raster.labelWmm, heightMM: Raster.labelHmm, density: density)
        let status = try Y813Link().send(job, log: log)
        log("print: status \(status.map { String(format: "0x%02X", $0) } ?? "none")")
    } catch { fail("\(error)") }

case "serve":
    signal(SIGPIPE, SIG_IGN)
    let service = PrinterService(port: port, density: density, log: log)
    do {
        try HTTPServer(port: port, handler: service.handle).start()
    } catch { fail("\(error)") }
    log("serving ipp://127.0.0.1:\(port)/ipp/print (density \(density))")
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()

default:
    fail("unknown command \(command)")
}
