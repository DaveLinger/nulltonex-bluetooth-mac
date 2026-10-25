// CoreBluetooth sender for the Y813. Port of src/y813/ble.py: same characteristics, write
// pattern (17-byte header, 600 ms pause, 244-byte write-without-response chunks) and ESC!? status.
// Blocking API for the serial job queue; delegate callbacks run on a private queue.

import CoreBluetooth
import Foundation

enum BLEError: Error, CustomStringConvertible {
    case unauthorized, unavailable(String), notFound, connectFailed(String), missingCharacteristic
    case timeout(String), disconnected
    /// Failure after at least one data write: the printer may have part of the job, so never retry.
    case duringTransfer(String)

    var description: String {
        switch self {
        case .unauthorized: return "Bluetooth permission not granted (System Settings > Privacy & Security > Bluetooth)"
        case .unavailable(let s): return "Bluetooth unavailable: \(s)"
        case .notFound: return "printer not found (is it on, in range, and not connected to Pixmate?)"
        case .connectFailed(let s): return "connect failed: \(s)"
        case .missingCharacteristic: return "printer is missing the expected ISSC UART characteristics"
        case .timeout(let s): return "timed out \(s)"
        case .disconnected: return "printer disconnected during the job"
        case .duringTransfer(let s): return "failed mid-transfer (not retried, check the printer): \(s)"
        }
    }
}

final class Y813Link: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    static let writeUUID = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
    static let notifyUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
    static let headerPause = 0.6
    static let pace = 0.006

    private let namePrefix: String
    private let q = DispatchQueue(label: "y813.ble")
    private let cond = NSCondition()
    private var central: CBCentralManager?
    private var knownID: UUID?

    // State guarded by `cond`.
    private var state: CBManagerState = .unknown
    private var peripheral: CBPeripheral?
    private var connected = false
    private var failure: String?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var notifying = false
    private var servicesDone = false
    private var charsDone = false
    private var readyToSend = false
    private var notifications: [Data] = []

    init(namePrefix: String = "Y813") { self.namePrefix = namePrefix }

    /// Create the central now so macOS shows the Bluetooth permission prompt at launch,
    /// not in the middle of the first print job.
    func prepare() { if central == nil { central = CBCentralManager(delegate: self, queue: q) } }

    private func update(_ body: () -> Void) { cond.lock(); body(); cond.broadcast(); cond.unlock() }

    private func wait(_ seconds: Double, _ what: String, until done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        cond.lock()
        defer { cond.unlock() }
        while !done() {
            if failure != nil { return }
            if !cond.wait(until: deadline) { if done() { return }; throw BLEError.timeout(what) }
        }
    }

    /// Send one job; returns the status byte answered to the trailing ESC!?, or nil if none arrived.
    func send(_ job: Data, log: (String) -> Void) throws -> UInt8? {
        prepare()
        try wait(5, "waiting for Bluetooth") { state != .unknown && state != .resetting }
        switch state {
        case .poweredOn: break
        case .unauthorized: throw BLEError.unauthorized
        default: throw BLEError.unavailable("state \(state.rawValue)")
        }

        update {
            peripheral = nil; connected = false; failure = nil; writeChar = nil; notifyChar = nil
            notifying = false; servicesDone = false; charsDone = false; notifications = []
        }
        defer { disconnect() }

        let p = try findPrinter(log: log)
        log("connecting to \(p.name ?? "?") (\(p.identifier))")
        q.sync { central!.connect(p) }
        try wait(15, "connecting") { connected }
        try check()

        q.sync { p.delegate = self; p.discoverServices([Self.service]) }
        try wait(10, "discovering services") { servicesDone }
        try check()
        try wait(10, "discovering characteristics") { charsDone }
        try check()
        guard let w = writeChar, let n = notifyChar else { throw BLEError.missingCharacteristic }
        q.sync { p.setNotifyValue(true, for: n) }
        try wait(5, "enabling notifications") { notifying }
        try check()

        let writes = TSPL.planWrites(job)
        log("sending \(job.count) bytes in \(writes.count) writes")
        do {
            for (i, chunk) in writes.enumerated() {
                // Never call q.sync while holding `cond`: delegate callbacks on q need it.
                while !q.sync(execute: { p.canSendWriteWithoutResponse }) {
                    try wait(5, "for write buffer") { readyToSend }
                    update { readyToSend = false }
                    try check()
                }
                try check()
                q.sync { p.writeValue(chunk, for: w, type: .withoutResponse) }
                Thread.sleep(forTimeInterval: i == 0 && chunk.starts(with: Data("CLS".utf8)) ? Self.headerPause : Self.pace)
            }
        } catch {
            throw BLEError.duringTransfer("\(error)")
        }
        // A missing status reply after a complete transfer is not an error; the label usually printed.
        try? wait(5, "for status") { !notifications.isEmpty }
        cond.lock(); let first = notifications.first; cond.unlock()
        return first?.first
    }

    private func check() throws {
        cond.lock(); let f = failure; let c = connected; cond.unlock()
        if let f { throw BLEError.connectFailed(f) }
        if !c { throw BLEError.disconnected }
    }

    private func findPrinter(log: (String) -> Void) throws -> CBPeripheral {
        if let id = knownID, let p = q.sync(execute: { central!.retrievePeripherals(withIdentifiers: [id]).first }) {
            update { peripheral = p }
            return p
        }
        log("scanning for \(namePrefix)*")
        q.sync { central!.scanForPeripherals(withServices: nil) }
        defer { q.sync { central!.stopScan() } }
        do { try wait(12, "scanning") { peripheral != nil } } catch { throw BLEError.notFound }
        cond.lock(); let p = peripheral!; cond.unlock()
        knownID = p.identifier
        return p
    }

    private func disconnect() {
        cond.lock(); let p = peripheral; cond.unlock()
        if let p { q.sync { central?.cancelPeripheralConnection(p) } }
        try? wait(3, "disconnecting") { !connected }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let names: [CBManagerState: String] = [.unknown: "unknown", .resetting: "resetting", .unsupported: "unsupported",
                                               .unauthorized: "unauthorized", .poweredOff: "poweredOff", .poweredOn: "poweredOn"]
        log("bluetooth state: \(names[c.state] ?? "\(c.state.rawValue)") (authorization \(CBManager.authorization.rawValue))")
        update { state = c.state }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.hasPrefix(namePrefix) else { return }
        update { if peripheral == nil { peripheral = p } }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { update { connected = true } }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        update { failure = error?.localizedDescription ?? "unknown error" }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        update { connected = false }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            update { servicesDone = true; charsDone = true }
            return
        }
        p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
        update { servicesDone = true }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        update {
            writeChar = s.characteristics?.first { $0.uuid == Self.writeUUID }
            notifyChar = s.characteristics?.first { $0.uuid == Self.notifyUUID }
            charsDone = true
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        update { if let error { failure = "notify: \(error.localizedDescription)" } else { notifying = ch.isNotifying } }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.notifyUUID, let v = ch.value else { return }
        update { notifications.append(v) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { update { readyToSend = true } }
}

/// First-run helper: triggers the Bluetooth permission prompt and reports the user's answer.
/// Run via LaunchServices (`open -W -a … --args authorize`); launchd-started instances may
/// never get a visible prompt. Logs "authorize: allowed|denied|timeout" and exits 0/2/3.
final class BluetoothAuthorizer: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?

    func run(timeout: TimeInterval = 180) {
        central = CBCentralManager(delegate: self, queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.finish("timeout", 3) }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch CBManager.authorization {
        case .allowedAlways: finish("allowed", 0)
        case .denied, .restricted: finish("denied", 2)
        default: break  // still waiting for the user
        }
    }

    private func finish(_ result: String, _ code: Int32) {
        log("authorize: \(result)")
        exit(code)
    }
}

/// Classic TSPL <ESC>!? bits. Only 0x00 (ready) has been observed on the Y813.
enum PrinterStatus {
    static func reasons(_ b: UInt8) -> [String] {
        var r: [String] = []
        if b & 0x01 != 0 || b & 0x40 != 0 { r.append("cover-open") }
        if b & 0x02 != 0 { r.append("media-jam") }
        if b & 0x04 != 0 { r.append("media-empty") }
        if b & 0x08 != 0 { r.append("marker-supply-empty") }
        if b & 0x10 != 0 { r.append("paused") }
        if b & 0x80 != 0 { r.append("other") }
        return r  // 0x20 "printing" is busy, not an error
    }
}
