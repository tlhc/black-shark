import CoreBluetooth
import Foundation
import wchar_h
import xlocale
import IOKit
import IOKit.pwr_mgt

// MagCooler 6 Max: presets and status frame from romestylez/BlackSharkLib.swift docs/magcooler-6-series.md;
// custom 1-5 (06 05 00 00 04 n) hardware-verified here at a constant 8/14/18/25/40 W
let serviceUUID = CBUUID(string: "0000A0A0-3C17-D293-8E48-14FE2E4DA212")
let writeUUID = CBUUID(string: "A001")
let notifyUUID = CBUUID(string: "A002")
let pollFrame = Data([0x05, 0x06, 0x20, 0x00, 0x00])
let maxLevel = 5
let levelWatts = [0, 8, 14, 18, 25, 40]
let maxWatts = 40.0

// Calibration knobs
// Deep cooling starts once die is predicted here, ahead of the measured Mac fan start (die-side sensors ~60 C)
let deepCoolDie = 50.0
let fanStartDie = 58.0
let hysteresis = 3.0
let dwell: TimeInterval = 10
let coldBand = 1
let hardFloorMargin = 2
let coldDepth = 4
// In a measured cycle the Mac fan restarted 10 s after stopping, so full cooling outlasts every stop by this much
let postCoolSeconds: TimeInterval = 90
// Reduce the upward ramp near target to leave time for the plate response.
let fastRampGap = 4
let nearTargetSettle: TimeInterval = 5
let stepDownSettle: TimeInterval = 1
let stepUpSettle: TimeInterval = 3
let connectionTimeout: TimeInterval = 10
let reconnectDelay: TimeInterval = 2
let telemetryMaxAge: TimeInterval = 10
let confirmDelay: TimeInterval = 1
let confirmTimeout: TimeInterval = 3
let shutdownWait: TimeInterval = 8
let watchdogWait: TimeInterval = 30
let dieHoldSeconds: TimeInterval = 5
let slopeSeconds: TimeInterval = 10
// The cooler needs about 38 s from off to a plate at target (measured), so the prediction looks this far ahead
let leadSeconds: TimeInterval = 30

func ArgValue(_ flag: String) -> Double? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}
let tickInterval: TimeInterval = max(0.1, ArgValue("--tick") ?? 1)
var baseTarget = Int(ArgValue("--cold") ?? 10)

typealias Telemetry = (cold: Int, hot: Int, rpm: Int, watts: Int)

func ModeFrame(_ level: Int) -> Data {
    Data([0x06, 0x05, 0x00, 0x00] + (level == 0 ? [0xFB, 0x00] : [0x04, UInt8(level)]))
}

func LevelName(_ level: Int) -> String {
    level == 0 ? "off" : "c\(level)"
}

func SamplesIn(_ seconds: TimeInterval) -> Int {
    max(1, Int((seconds / tickInterval).rounded()))
}

// Least-squares slope of evenly spaced samples, per second
func Slope(_ ys: [Double], dt: Double) -> Double {
    guard ys.count >= 3 else { return 0 }
    let xMean = Double(ys.count - 1) / 2
    let yMean = ys.reduce(0, +) / Double(ys.count)
    var num = 0.0
    var den = 0.0
    for (i, y) in ys.enumerated() {
        num += (Double(i) - xMean) * (y - yMean)
        den += (Double(i) - xMean) * (Double(i) - xMean)
    }
    return num / den / dt
}

func PredictDie(_ held: [Double], dt: Double) -> Double {
    guard let last = held.last else { return 0 }
    return last + max(0, Slope(held, dt: dt)) * leadSeconds
}

// The Mac fan lingers at minimum speed long after die has cooled (128 s in a measured cycle) while slow chassis
// sensors decide when it stops, so fan activity, or die predicted to start it, earns the deepest plate target.
// Otherwise the plate is still held at the base target, banking chassis cold for the next burst.
func FanActive(spinning: Bool, sinceSpin: TimeInterval) -> Bool {
    spinning || sinceSpin < postCoolSeconds
}

func DeepCool(was: Bool, diePredicted: Double, fanActive: Bool) -> Bool {
    fanActive || diePredicted >= deepCoolDie || (was && diePredicted >= deepCoolDie - hysteresis)
}

func ColdTarget(deep: Bool) -> Int {
    baseTarget - (deep ? coldDepth : 0)
}

// Holds the cold plate inside target +/- coldBand without running above cap. No plate reading, or a plate
// already past the hard floor, means off at once; cooling restarts only above the band.
func NextLevel(_ cur: Int, cap: Int, target: Int, cold: Int?, sinceChange: TimeInterval) -> Int {
    guard let cold else { return 0 }
    if cold < target - coldBand - hardFloorMargin {
        return 0
    }
    if cold < target - coldBand {
        return sinceChange >= stepDownSettle ? max(cur - 1, 0) : cur
    }
    if cap < cur {
        return sinceChange >= dwell ? cap : cur
    }
    let riseSettle = cold > target + fastRampGap ? stepUpSettle : nearTargetSettle
    if cold > target + coldBand && cur < cap && sinceChange >= riseSettle {
        return cur + 1
    }
    return cur
}

func MagnusGamma(_ t: Double) -> Double {
    17.62 * t / (243.12 + t)
}

func CondensingRH(surface: Double, room: Double) -> Double {
    100 * exp(MagnusGamma(surface) - MagnusGamma(room))
}

func ParseTelemetry(_ b: [UInt8]) -> Telemetry? {
    guard b.count >= 11, b[0] == 0x8B, b[1] == 0x06, b[2] == 0x20, b[3] == 0x00 else { return nil }
    return (Int(Int8(bitPattern: b[4])), Int(Int8(bitPattern: b[5])), Int(b[6]) | Int(b[7]) << 8, Int(b[8]))
}

func LevelForWatts(_ watts: Int) -> Int {
    levelWatts.indices.min { abs(levelWatts[$0] - watts) < abs(levelWatts[$1] - watts) } ?? 0
}

// Off only at exactly 0 W; powered levels by their nearest constant power
func ShowsLevel(_ level: Int, watts: Int) -> Bool {
    level == 0 ? watts == 0 : LevelForWatts(watts) == level
}

// The cooler's 85 05 00 00 01 write acks carry no command id, so a level counts as applied only when telemetry
// received at least confirmDelay after the command reports that level's constant power (it lagged ~1 s on hardware).
func Confirms(level: Int, sentAt: Date, telemetryAt: Date, watts: Int) -> Bool {
    telemetryAt.timeIntervalSince(sentAt) >= confirmDelay && ShowsLevel(level, watts: watts)
}

// A confirmed level that later telemetry contradicts was changed outside this program (app, button, firmware)
func Diverged(applied: Int?, pending: Bool, sinceSend: TimeInterval, watts: Int) -> Bool {
    guard let applied, !pending, sinceSend >= confirmDelay else { return false }
    return !ShowsLevel(applied, watts: watts)
}

// Apple Silicon die sensors through the private IOHIDEventSystemClient API, readable without root
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
func Sym<T>(_ name: String, _ type: T.Type) -> T {
    unsafeBitCast(dlsym(iokit, name)!, to: type)
}
let hidCreate = Sym("IOHIDEventSystemClientCreate", (@convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?).self)
let hidSetMatching = Sym("IOHIDEventSystemClientSetMatching", (@convention(c) (AnyObject, CFDictionary) -> Int32).self)
let hidCopyServices = Sym("IOHIDEventSystemClientCopyServices", (@convention(c) (AnyObject) -> Unmanaged<CFArray>?).self)
let hidCopyProperty = Sym("IOHIDServiceClientCopyProperty", (@convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?).self)
let hidCopyEvent = Sym("IOHIDServiceClientCopyEvent", (@convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?).self)
let hidGetFloat = Sym("IOHIDEventGetFloatValue", (@convention(c) (AnyObject, Int32) -> Double).self)
let temperatureEvent: Int32 = 15

let hidClient = hidCreate(kCFAllocatorDefault)!.takeRetainedValue()

func LoadDieSensors() -> [AnyObject] {
    _ = hidSetMatching(hidClient, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    let all = (hidCopyServices(hidClient)?.takeRetainedValue() as? [AnyObject]) ?? []
    return all.filter {
        (hidCopyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String)?.hasPrefix("PMU tdie") == true
    }
}
var dieSensors = LoadDieSensors()

func ReadDieMax() -> Double? {
    dieSensors.compactMap { hidCopyEvent($0, Int64(temperatureEvent), 0, 0)?.takeRetainedValue() }
        .map { hidGetFloat($0, temperatureEvent << 16) }
        .filter { $0 > 0 && $0 < 150 }
        .max()
}

// Mac fan RPM from AppleSMC, readable without root. Param block offsets (offsetof-checked):
// key@0 dataSize@28 dataType@32 result@40 data8@42 bytes@48, 80 bytes total
var smcConn: io_connect_t = 0
_ = IOServiceOpen(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")), mach_task_self_, 0, &smcConn)

func FourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

func SmcCall(_ input: [UInt8]) -> [UInt8]? {
    var inBuf = input
    var outBuf = [UInt8](repeating: 0, count: 80)
    var outSize = outBuf.count
    let kr = IOConnectCallStructMethod(smcConn, 2, &inBuf, inBuf.count, &outBuf, &outSize)
    return kr == kIOReturnSuccess && outBuf[40] == 0 ? outBuf : nil
}

func SmcFloat(_ key: String) -> Float? {
    var p = [UInt8](repeating: 0, count: 80)
    withUnsafeBytes(of: FourCC(key)) { p.replaceSubrange(0..<4, with: $0) }
    p[42] = 9
    guard let info = SmcCall(p),
          info[32..<36].withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == FourCC("flt ") else { return nil }
    p.replaceSubrange(28..<32, with: info[28..<32])
    p[42] = 5
    return SmcCall(p)?[48..<52].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
}

func MacFanRPM() -> [Float] {
    ["F0Ac", "F1Ac"].compactMap(SmcFloat)
}

func FanText(_ rpm: [Float]) -> String {
    rpm.isEmpty ? "?" : rpm.map { String(format: "%.0f", $0) }.joined(separator: " / ")
}

let fanMinRPM = Double(SmcFloat("F0Mn") ?? 2317)
let fanMaxRPM = Double(SmcFloat("F0Mx") ?? 7826)

func FanFraction(_ rpm: [Float]) -> Double? {
    guard let top = rpm.max(), top > 0 else { return nil }
    return min(max((Double(top) - fanMinRPM) / (fanMaxRPM - fanMinRPM), 0), 1)
}

let tuiMode = isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0

let clockFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func Clock(_ d: Date = Date()) -> String {
    clockFormat.string(from: d)
}

@discardableResult
func WriteOut(_ s: String) -> Bool {
    var s = s
    return s.withUTF8 { buf in
        guard let base = buf.baseAddress else { return true }
        var offset = 0
        while offset < buf.count {
            let n = write(STDOUT_FILENO, base + offset, buf.count - offset)
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

// A full pipe or a stalled terminal blocks write(), so output runs on its own thread and the control loop never
// waits on it. Log lines are bounded and TUI frames coalesce to the latest one.
final class Output: @unchecked Sendable {
    private let cond = NSCondition()
    private var lines: [String] = []
    private var frame: String?
    private var busy = false
    private var brokenPipe = false

    init() {
        Thread.detachNewThread { self.Run() }
    }

    func Line(_ s: String) {
        cond.lock()
        if lines.count < 1000 {
            lines.append(s)
        }
        cond.signal()
        cond.unlock()
    }

    func Frame(_ s: String?) {
        cond.lock()
        frame = s
        cond.signal()
        cond.unlock()
    }

    var broken: Bool {
        cond.lock()
        defer { cond.unlock() }
        return brokenPipe
    }

    func Flush(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        while (busy || !lines.isEmpty || frame != nil) && cond.wait(until: deadline) {}
        cond.unlock()
    }

    private func Run() {
        while true {
            cond.lock()
            while lines.isEmpty && frame == nil {
                cond.wait()
            }
            let text = lines.joined() + (frame ?? "")
            lines.removeAll()
            frame = nil
            busy = true
            cond.unlock()
            let ok = WriteOut(text)
            let pipeGone = !ok && errno == EPIPE
            cond.lock()
            busy = false
            brokenPipe = brokenPipe || pipeGone
            cond.broadcast()
            cond.unlock()
        }
    }
}

let output = Output()

func Log(_ s: String) {
    output.Line("[\(Clock())] \(s)\n")
}

final class Controller: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var cooler: CBPeripheral?
    var writeChar: CBCharacteristic?
    var setupTimer: Timer?
    var notifyChar: CBCharacteristic?
    var awaitingTelemetry = false
    var rssi: Int?
    var telemetry: Telemetry?
    var telemetryAt = Date.distantPast
    var level = 0
    var applied: Int?
    var pending: (level: Int, sentAt: Date, tries: Int)?
    var everConnected = false
    var dieFault = false
    var lastChange = Date.distantPast
    var lastSentAt = Date.distantPast
    var timer: Timer?
    var paused = CommandLine.arguments.contains("--off")
    var holdOff = false
    var dieRecent: [Double] = []
    var dieHeld: [Double] = []
    var die = 0.0
    var slope = 0.0
    var diePredicted = 0.0
    var fans: [Float] = []
    var lastSpin = Date.distantPast
    var fanActive = false
    var deep = false
    var target = baseTarget
    var sleeping = false
    var events: [(Date, String)] = []
    var chartHistory: [ChartSample] = []
    var coldHistory: [Double] = []
    var dieHistory: [Double] = []
    var fanHistory: [Double] = []
    var preTick: (() -> Void)?
    var onTick: (() -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(timeInterval: tickInterval, target: self, selector: #selector(Tick), userInfo: nil, repeats: true)
    }

    var connected: Bool { writeChar != nil }
    var fan: Double? { FanFraction(fans) }

    func Event(_ s: String) {
        events.append((Date(), s))
        if events.count > 5 {
            events.removeFirst()
        }
        if !tuiMode {
            Log(s)
        }
    }

    func ClearConnection() {
        setupTimer?.invalidate()
        setupTimer = nil
        cooler?.delegate = nil
        cooler = nil
        writeChar = nil
        notifyChar = nil
        awaitingTelemetry = false
        telemetry = nil
        telemetryAt = .distantPast
        applied = nil
        pending = nil
        rssi = nil
        level = 0
    }

    func Recover(_ reason: String) {
        Event(reason + "; retrying in 2 s")
        let old = central!
        old.delegate = nil
        if old.state == .poweredOn {
            old.stopScan()
            if let p = cooler { old.cancelPeripheralConnection(p) }
        }
        ClearConnection()
        // A new manager isolates the next attempt from callbacks queued by the cancelled session.
        setupTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.setupTimer = nil
            self.central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func AwaitSetup(_ stage: String) {
        setupTimer?.invalidate()
        setupTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Preserve the writable link while sleep handling polls for confirmed off.
            if self.sleeping && self.connected {
                self.AwaitSetup(stage)
                return
            }
            self.Recover(stage + " timed out")
        }
    }

    // A cooler already linked to this Mac (e.g. by a stalled controller the watchdog is replacing) no longer
    // advertises, so attach to the shared connection before falling back to a scan
    func Scan() {
        guard central.state == .poweredOn, cooler == nil, setupTimer == nil else { return }
        if let p = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            Event("cooler already connected to this Mac, attaching")
            Attach(p)
            return
        }
        Event("scanning for MagCooler 6 Max")
        central.scanForPeripherals(withServices: nil)
    }

    func Attach(_ p: CBPeripheral) {
        cooler = p
        p.delegate = self
        AwaitSetup("connection")
        central.connect(p)
    }

    @discardableResult
    func Send(_ data: Data) -> Bool {
        guard let p = cooler, let w = writeChar else { return false }
        p.writeValue(data, for: w, type: w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        return true
    }

    // Without-response writes are best effort, so the level is resent until telemetry confirms it. Gating on
    // canSendWriteWithoutResponse starved mode writes behind the poll on hardware.
    func ApplyLevel() {
        guard connected, applied != level else { return }
        if let p = pending, p.level == level, Date().timeIntervalSince(p.sentAt) < confirmTimeout {
            return
        }
        let tries = pending?.level == level ? (pending?.tries ?? 0) + 1 : 1
        guard Send(ModeFrame(level)) else { return }
        applied = nil
        pending = (level, Date(), tries)
        lastSentAt = Date()
        if tries == 3 {
            Event("\(LevelName(level)) not confirmed, retrying")
        }
    }

    func Push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 600 {
            history.removeFirst()
        }
    }

    @objc func Tick() {
        preTick?()
        if connected {
            cooler?.readRSSI()
        }
        if Date().timeIntervalSince(telemetryAt) > telemetryMaxAge {
            telemetry = nil
        }
        fans = MacFanRPM()
        if let dieNow = ReadDieMax() ?? ReloadDieSensors() {
            if dieFault {
                Event("die sensors back")
            }
            dieFault = false
            dieRecent.append(dieNow)
            if dieRecent.count > SamplesIn(dieHoldSeconds) {
                dieRecent.removeFirst()
            }
            die = dieRecent.max() ?? dieNow
            dieHeld.append(die)
            if dieHeld.count > SamplesIn(slopeSeconds) {
                dieHeld.removeFirst()
            }
            slope = Slope(dieHeld, dt: tickInterval)
            diePredicted = PredictDie(dieHeld, dt: tickInterval)
            Push(die, to: &dieHistory)
        } else {
            if !dieFault {
                Event("die sensors unreadable: no die prediction, deep cooling follows the Mac fan only")
            }
            dieFault = true
            diePredicted = 0
        }
        if fan != nil {
            lastSpin = Date()
        }
        fanActive = FanActive(spinning: fan != nil, sinceSpin: Date().timeIntervalSince(lastSpin))
        deep = DeepCool(was: deep, diePredicted: diePredicted, fanActive: fanActive)
        target = ColdTarget(deep: deep)
        let next = paused || holdOff || sleeping ? 0 : NextLevel(level, cap: maxLevel, target: target, cold: telemetry?.cold,
                                                                 sinceChange: Date().timeIntervalSince(lastChange))
        if next != level {
            level = next
            lastChange = Date()
        }
        ApplyLevel()
        Send(pollFrame)
        if let t = telemetry {
            Push(Double(t.cold), to: &coldHistory)
        }
        Push(Double(fans.max() ?? 0), to: &fanHistory)
        chartHistory.append(ChartSample(at: Date(), cold: telemetry.map { Double($0.cold) },
                                        die: dieFault ? nil : die, fan: fans.max().map { Double($0) },
                                        watts: telemetry.map { Double($0.watts) }))
        if chartHistory.count > 1200 { chartHistory.removeFirst() }
        onTick?()
    }

    func ReloadDieSensors() -> Double? {
        dieSensors = LoadDieSensors()
        return ReadDieMax()
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c === central, c.delegate != nil else { return }
        guard c.state == .poweredOn else {
            Event("bluetooth state \(c.state.rawValue)")
            ClearConnection()
            return
        }
        Scan()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard c === central, c.delegate != nil, c.state == .poweredOn,
              cooler == nil, setupTimer == nil,
              let name = ad[CBAdvertisementDataLocalNameKey] as? String,
              name.lowercased().replacingOccurrences(of: " ", with: "").contains("6max") else { return }
        self.rssi = rssi.intValue
        Event("found \(name)")
        c.stopScan()
        Attach(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard c === central, c.delegate != nil else { return }
        guard p === cooler else {
            if c.state == .poweredOn { c.cancelPeripheralConnection(p) }
            return
        }
        everConnected = true
        AwaitSetup("service discovery")
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard c === central, c.delegate != nil, p === cooler else { return }
        Recover("connect failed: \(error?.localizedDescription ?? "-")")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard c === central, c.delegate != nil, p === cooler else { return }
        Recover("disconnected")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === cooler else { return }
        guard error == nil, let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            Recover("service discovery failed or A0A0 missing")
            return
        }
        AwaitSetup("characteristic discovery")
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === cooler, s.uuid == serviceUUID else { return }
        let chars = s.characteristics ?? []
        guard error == nil,
              let n = chars.first(where: { $0.uuid == notifyUUID }),
              n.properties.contains(.notify) || n.properties.contains(.indicate),
              let w = chars.first(where: { $0.uuid == writeUUID }),
              w.properties.contains(.write) || w.properties.contains(.writeWithoutResponse) else {
            Recover("required characteristics missing or unusable")
            return
        }
        writeChar = w
        notifyChar = n
        applied = nil
        pending = nil
        awaitingTelemetry = true
        AwaitSetup("notification subscription")
        p.setNotifyValue(true, for: n)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard p === cooler, ch === notifyChar else { return }
        guard error == nil, ch.isNotifying else {
            Recover("notification subscription failed")
            return
        }
        if awaitingTelemetry { AwaitSetup("first telemetry") }
        Send(pollFrame)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard p === cooler, ch === notifyChar, ch.isNotifying,
              error == nil, let v = ch.value, let t = ParseTelemetry([UInt8](v)) else { return }
        if awaitingTelemetry {
            awaitingTelemetry = false
            setupTimer?.invalidate()
            setupTimer = nil
            Event("connected")
        }
        telemetry = t
        telemetryAt = Date()
        if let p = pending, Confirms(level: p.level, sentAt: p.sentAt, telemetryAt: telemetryAt, watts: t.watts) {
            applied = p.level
            pending = nil
            Event("set \(LevelName(p.level))")
        } else if Diverged(applied: applied, pending: pending != nil, sinceSend: telemetryAt.timeIntervalSince(lastSentAt),
                           watts: t.watts), let a = applied {
            Event("cooler reports \(t.watts) W, expected \(LevelName(a)); resending")
            applied = nil
        }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if p === cooler, error == nil {
            rssi = RSSI.intValue
        }
    }

    func StatusLine() -> String {
        var s = String(format: "die %.1fC %+.2f/s pred %.1fC | mac fan %@ | %@ goal %d%@", die, slope, diePredicted,
                       FanText(fans), connected ? LevelName(level) : "-", target, deep ? " deep" : "")
        if let t = telemetry {
            s += " | cold \(t.cold)C | hot \(t.hot)C \(t.rpm)rpm \(t.watts)W"
        }
        return s
    }
}

enum Ink {
    static let dim = "38;5;244"
    static let border = "38;5;239"
    static let text = "38;5;252"
    static let title = "1;38;5;255"
    static let green = "38;5;114"
    static let yellow = "38;5;179"
    static let red = "38;5;203"
    static let cyan = "38;5;80"
    static let magenta = "38;5;170"
    static let orange = "38;5;215"
    static let active = "1;38;5;16;48;5;80"
}

let displayLocale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)

func CellWidth(_ character: Character) -> Int {
    let widths = character.unicodeScalars.map { max(0, Int(wcwidth_l(Int32($0.value), displayLocale))) }
    if character.unicodeScalars.contains(where: { (0x1F1E6...0x1F1FF).contains($0.value) }) { return 2 }
    return widths.max() ?? 0
}

func TextWidth(_ text: String) -> Int {
    text.reduce(0) { $0 + CellWidth($1) }
}

func TextPrefix(_ text: String, width: Int) -> String {
    var used = 0
    return String(text.prefix { character in
        used += CellWidth(character)
        return used <= max(0, width)
    })
}

struct Row {
    var plain = ""
    var spans: [(String, String)] = []

    mutating func Add(_ text: String, _ ink: String = Ink.text) {
        // Device errors may contain terminal controls; preserve printable Unicode only.
        let clean = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        plain += clean
        spans.append((clean, ink))
    }

    mutating func Append(_ row: Row) {
        plain += row.plain
        spans += row.spans
    }

    func Clipped(width: Int) -> Row {
        var result = Row()
        var remaining = max(0, width)
        for (text, ink) in spans {
            let part = TextPrefix(text, width: remaining)
            result.Add(part, ink)
            remaining -= TextWidth(part)
            if part != text { break }
        }
        return result
    }

    func Fitted(width: Int) -> String {
        Clipped(width: width).spans.map { text, ink in
            text.isEmpty ? "" : "\u{1B}[\(ink)m" + text + "\u{1B}[0m"
        }.joined()
    }

    mutating func PadTo(_ col: Int) {
        Add(String(repeating: " ", count: max(0, col - TextWidth(plain))))
    }

    mutating func AddRight(_ s: String, _ ink: String, width: Int) {
        PadTo(width - TextWidth(s))
        Add(s, ink)
    }
}

func TextRow(_ text: String, _ ink: String = Ink.text) -> Row {
    var row = Row()
    row.Add(text, ink)
    return row
}

func Bar(_ fraction: Double, width: Int) -> String {
    guard width > 0 else { return "" }
    let value = fraction.isFinite ? min(max(fraction, 0), 1) : 0
    let eighths = Int((value * Double(width * 8)).rounded())
    let partial = Array(" ▏▎▍▌▋▊▉")
    let full = eighths / 8
    let tail = eighths % 8
    return String(repeating: "█", count: full) + (tail > 0 ? String(partial[tail]) : "")
        + String(repeating: "░", count: width - full - (tail > 0 ? 1 : 0))
}

func DieInk(_ t: Double) -> String {
    t >= fanStartDie ? Ink.red : (t >= deepCoolDie ? Ink.yellow : Ink.orange)
}

func FanInk(_ f: Double?) -> String {
    guard let f else { return Ink.green }
    return f < 0.25 ? Ink.yellow : Ink.red
}

struct ChartSample {
    let at: Date
    let cold: Double?
    let die: Double?
    let fan: Double?
    let watts: Double?
}

func Panel(_ title: String, width: Int, height: Int, body: [Row], ink: String = Ink.border) -> [Row] {
    let label = TextPrefix(" \(title) ", width: width - 2)
    var rows = [TextRow("┌" + label + String(repeating: "─", count: max(0, width - 2 - TextWidth(label))) + "┐", ink)]
    for index in 0..<max(0, height - 2) {
        var row = TextRow("│", ink)
        row.Add(" ")
        if index < body.count { row.Append(body[index].Clipped(width: width - 4)) }
        row.PadTo(width - 1)
        row.Add("│", ink)
        rows.append(row)
    }
    rows.append(TextRow("└" + String(repeating: "─", count: max(0, width - 2)) + "┘", ink))
    return rows
}

func Beside(_ left: [Row], _ right: [Row]) -> [Row] {
    zip(left, right).map { a, b in
        var row = a
        row.Add(" ")
        row.Append(b)
        return row
    }
}

// A Braille cell has two columns and four rows of dots; gaps interrupt interpolation.
func Plot(_ points: [(Date, Double?)], width: Int, height: Int, now: Date,
          range: ClosedRange<Double>, ink: String, references: [(Double, String)] = [], step: Bool = false) -> [Row] {
    let columns = max(1, width - 7)
    let pixelWidth = columns * 2
    let pixelHeight = max(1, height) * 4
    var dots = Array(repeating: Array(repeating: UInt8(0), count: columns), count: max(1, height))
    let bits: [[UInt8]] = [[1, 2, 4, 64], [8, 16, 32, 128]]
    let span = max(1, range.upperBound - range.lowerBound)
    func Y(_ value: Double) -> Int {
        Int(((range.upperBound - min(max(value, range.lowerBound), range.upperBound)) / span * Double(pixelHeight - 1)).rounded())
    }
    func Dot(_ x: Int, _ y: Int) {
        guard x >= 0 && x < pixelWidth && y >= 0 && y < pixelHeight else { return }
        dots[y / 4][x / 2] |= bits[x % 2][y % 4]
    }
    func Segment(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        let steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in 0...steps {
            let ratio = Double(i) / Double(steps)
            Dot(Int((Double(x0) + Double(x1 - x0) * ratio).rounded()),
                Int((Double(y0) + Double(y1 - y0) * ratio).rounded()))
        }
    }
    var previous: (x: Int, y: Int, at: Date)?
    for (at, value) in points {
        let age = now.timeIntervalSince(at)
        guard age >= 0 && age <= 120, let value, value.isFinite else { previous = nil; continue }
        let x = Int(((120 - age) / 120 * Double(pixelWidth - 1)).rounded())
        let y = Y(value)
        if let p = previous, at.timeIntervalSince(p.at) <= max(3 * tickInterval, 3) {
            if step { Segment(p.x, p.y, x, p.y); Segment(x, p.y, x, y) }
            else { Segment(p.x, p.y, x, y) }
        }
        Dot(x, y)
        previous = (x, y, at)
    }
    return (0..<max(1, height)).map { y in
        var row = Row()
        let value = range.upperBound - Double(y) / Double(max(1, height - 1)) * span
        let tick = y == 0 || y == height - 1 || (height >= 5 && y == height / 2)
        row.Add(tick ? String(format: "%5.0f │", value) : "      │", Ink.dim)
        let reference = references.first { Y($0.0) / 4 == y }
        for x in 0..<columns {
            if dots[y][x] != 0 {
                row.Add(String(UnicodeScalar(0x2800 + UInt32(dots[y][x]))!), ink)
            } else if let reference {
                let bit = bits[0][Y(reference.0) % 4]
                row.Add(String(UnicodeScalar(0x2800 + UInt32(bit))!), reference.1)
            } else {
                row.Add(" ")
            }
        }
        return row
    }
}

func TemperatureRange(_ values: [Double], including references: [Double]) -> ClosedRange<Double> {
    let values = values.filter(\.isFinite) + references
    let lo = floor(((values.min() ?? 0) - 2) / 5) * 5
    let hi = ceil(((values.max() ?? 10) + 2) / 5) * 5
    return lo...max(lo + 10, hi)
}

func ChartPanel(_ title: String, samples: [(Date, Double?)], width: Int, height: Int, now: Date,
                range: ClosedRange<Double>, ink: String, caption: String,
                references: [(Double, String)] = [], step: Bool = false) -> [Row] {
    var body = [TextRow(caption, ink)]
    body += Plot(samples, width: width - 4, height: height - 4, now: now, range: range,
                 ink: ink, references: references, step: step)
    var axis = TextRow("      -120s", Ink.dim)
    axis.AddRight("now", Ink.dim, width: width - 4)
    body.append(axis)
    return Panel(title, width: width, height: height, body: body)
}

let minWidth = 74
let frameHeight = 17

func RenderFrame(_ c: Controller, width cols: Int, height lines: Int) -> String {
    let w = min(max(0, cols - 1), 132)
    guard cols >= minWidth && lines >= frameHeight else {
        return TextPrefix("Resize to \(minWidth)x\(frameHeight) | [q] quit", width: w) + "\u{1B}[K"
    }
    let now = Date()
    let h = min(lines, 33)
    let wide = w >= 108 && h >= 30
    let fresh = c.connected && c.telemetry != nil && now.timeIntervalSince(c.telemetryAt) <= telemetryMaxAge
    let t = fresh ? c.telemetry : nil
    let mode = c.sleeping ? "SLEEP / OFF" : c.holdOff ? "WATCHDOG / HOLD OFF" : c.paused ? "PAUSED / OFF"
        : !c.connected ? "CONNECTING" : !fresh ? "WAITING FOR TELEMETRY" : c.deep ? "DEEP COOLING" : "BANKING COLD"
    let modeInk = c.sleeping || c.holdOff || c.paused || !fresh ? Ink.yellow : Ink.cyan
    var header = TextRow(" BLACK SHARK  /  MAGCOOLER 6 MAX", Ink.title)
    header.AddRight(Clock(), Ink.dim, width: w)
    var rows = [header]
    var status = TextRow(" " + mode, modeInk)
    let age = fresh ? String(format: "%.1fs ago", max(0, now.timeIntervalSince(c.telemetryAt))) : "STALE / UNKNOWN"
    status.AddRight((c.connected ? "BLE linked" : "BLE scanning") + "  telemetry " + age, fresh ? Ink.dim : Ink.yellow, width: w)
    rows.append(status)

    let leftWidth = (w - 1) / 2
    let rightWidth = w - 1 - leftWidth
    let fan = c.fans.isEmpty ? "UNKNOWN" : c.fan == nil ? "STOPPED" : "RUNNING"
    let mac = [
        TextRow(c.dieFault ? "die UNREADABLE" : String(format: "die %.1f C   %+.2f C/s", c.die, c.slope), c.dieFault ? Ink.red : DieInk(c.die)),
        TextRow(c.dieFault ? "prediction -- / sensor fault" : String(format: "next %.0fs: %.1f C", leadSeconds, c.diePredicted), Ink.dim),
        TextRow("fan \(FanText(c.fans)) rpm / \(fan)", c.fans.isEmpty ? Ink.yellow : FanInk(c.fan)),
        TextRow(c.fans.isEmpty ? "fan reading unavailable" : Bar(c.fan ?? 0, width: 16) + String(format: " %3.0f%%", (c.fan ?? 0) * 100), FanInk(c.fan)),
        TextRow(c.fanActive ? "deep: fan / post-cool window" : c.deep ? "deep: predicted temperature" : "base target / banking cold", Ink.dim),
    ]
    let cooler = [
        TextRow(t.map { "cold \($0.cold) C   target \(c.target) C" } ?? "cold --   target \(c.target) C", Ink.cyan),
        TextRow("band \(c.target - coldBand)..\(c.target + coldBand) / cut <\(c.target - coldBand - hardFloorMargin) C", Ink.dim),
        TextRow(t.map { "hot \($0.hot) C   delta \($0.hot - $0.cold) C" } ?? "hot -- / delta --", Ink.orange),
        TextRow(t.map { Bar(Double($0.watts) / maxWatts, width: 12) + "  \($0.watts) W" } ?? "power --", Ink.cyan),
        TextRow(t.map { "cooler fan \($0.rpm) rpm" } ?? "cooler fan --", Ink.dim),
    ]
    rows += Beside(Panel("MAC / THERMAL", width: leftWidth, height: 7, body: mac),
                   Panel("COOLER / PLATE", width: rightWidth, height: 7, body: cooler))

    var command = TextRow(" requested \(LevelName(c.level)) / confirmed \(c.applied.map { LevelName($0) } ?? "--")")
    let pending = c.pending.map { String(format: "PENDING %.1fs / try %d", max(0, now.timeIntervalSince($0.sentAt)), $0.tries) }
        ?? (c.applied == nil ? "UNCONFIRMED" : "CONFIRMED")
    command.AddRight(pending, c.pending == nil && c.applied != nil ? Ink.green : Ink.yellow, width: w)
    rows.append(command)
    var levels = TextRow(" ")
    for level in 0...maxLevel {
        levels.Add(" \(LevelName(level))/\(levelWatts[level])W ", c.applied == level ? Ink.active : c.level == level ? Ink.yellow : Ink.dim)
    }
    rows.append(levels)

    let samples = c.chartHistory.filter { now.timeIntervalSince($0.at) <= 120 }
    let cold = samples.map { ($0.at, $0.cold) }
    let die = samples.map { ($0.at, $0.die) }
    let target = Double(c.target)
    let floor = target - Double(coldBand + hardFloorMargin)
    let coldRange = TemperatureRange(cold.compactMap { $0.1 }, including: [floor, target + Double(coldBand)])
    let coldCaption = "C  target \(c.target) / band ±\(coldBand) / cut <\(Int(floor))"
    let references = [(target, Ink.green), (floor, Ink.red), (target - Double(coldBand), Ink.dim), (target + Double(coldBand), Ink.dim)]
    if h >= 24 {
        let reservedEvents = min(8, max(3, (h - 24) / 3 + 3))
        let powerHeight = wide ? 6 : 0
        let chartHeight = h - rows.count - reservedEvents - powerHeight - 2
        let coldPanel = ChartPanel("COLD PLATE / 120s", samples: cold, width: wide ? leftWidth : w, height: chartHeight,
                                   now: now, range: coldRange, ink: Ink.cyan, caption: coldCaption, references: references)
        if wide {
            let dieRange = TemperatureRange(die.compactMap { $0.1 }, including: [deepCoolDie, fanStartDie])
            rows += Beside(coldPanel, ChartPanel("MAC DIE / 120s", samples: die, width: rightWidth, height: chartHeight,
                now: now, range: dieRange, ink: Ink.orange, caption: "C  deep \(Int(deepCoolDie)) / fan ~\(Int(fanStartDie))",
                references: [(deepCoolDie, Ink.dim), (fanStartDie, Ink.red)]))
            rows += Beside(ChartPanel("COOLER POWER / 120s", samples: samples.map { ($0.at, $0.watts) },
                width: leftWidth, height: powerHeight, now: now, range: 0...maxWatts, ink: Ink.cyan, caption: "W  telemetry / stepped", step: true),
                ChartPanel("MAC FAN / 120s", samples: samples.map { ($0.at, $0.fan) }, width: rightWidth,
                    height: powerHeight, now: now, range: 0...fanMaxRPM, ink: Ink.green, caption: "rpm  measured / stepped", step: true))
        } else {
            rows += coldPanel
        }
    }
    let eventHeight = max(3, h - rows.count - 2)
    let events = c.events.reversed().map { TextRow(Clock($0.0) + "  " + $0.1, Ink.dim) }
    rows += Panel("RECENT EVENTS", width: w, height: eventHeight,
                  body: events.isEmpty ? [TextRow("Waiting for controller events", Ink.dim)] : events)
    let plate = c.target - coldBand
    rows.append(TextRow(String(format: " DEW estimate: %d C condenses above %.0f%% RH at 25 C room", plate,
                               CondensingRH(surface: Double(plate), room: 25)), Ink.yellow))
    var footer = TextRow(" [+/-] base \(baseTarget) C   [p] \(c.paused ? "resume" : "pause")   [q] off & quit", Ink.title)
    footer.AddRight(String(format: "tick %g s", tickInterval), Ink.dim, width: w)
    rows.append(footer)
    return rows.prefix(h).map { $0.Fitted(width: w) }.joined(separator: "\u{1B}[K\r\n") + "\u{1B}[K"
}

var savedTermios = termios()
var tuiActive = false

func TerminalSize() -> (cols: Int, lines: Int) {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return (80, 24) }
    return (Int(ws.ws_col), Int(ws.ws_row))
}

// IXON off so Ctrl-S cannot freeze the display; TCSANOW so restoring never waits for a stalled terminal to drain
func TuiEnter() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    raw.c_iflag &= ~tcflag_t(IXON)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    output.Line("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
    tuiActive = true
    atexit { TuiLeave() }
}

// Runs once: a second ESC[?1049l would restore the cursor saved on entry and let the shell overwrite the exit message
func TuiLeave() {
    guard tuiActive else { return }
    tuiActive = false
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
    output.Frame(nil)
    output.Line("\u{1B}[?25h\u{1B}[?1049l")
}

func SelfTest() -> Bool {
    let t = baseTarget
    let checks: [(String, Bool)] = [
        ("active Mac fan means deep cooling", DeepCool(was: false, diePredicted: 0, fanActive: true)),
        ("die predicted at the start point means deep cooling", DeepCool(was: false, diePredicted: deepCoolDie, fanActive: false)),
        ("cool die and idle fan hold the base target", !DeepCool(was: false, diePredicted: deepCoolDie - 1, fanActive: false)),
        ("deep cooling holds inside the hysteresis", DeepCool(was: true, diePredicted: deepCoolDie - 1, fanActive: false)),
        ("deep cooling ends past the hysteresis",
            !DeepCool(was: true, diePredicted: deepCoolDie - hysteresis - 1, fanActive: false)),
        ("unknown cold plate turns the cooler off", NextLevel(5, cap: 5, target: t, cold: nil, sinceChange: 100) == 0),
        ("plate below hard floor cuts power at once",
            NextLevel(5, cap: 5, target: t, cold: t - coldBand - hardFloorMargin - 1, sinceChange: 0) == 0),
        ("cold plate below band steps down", NextLevel(5, cap: 5, target: t, cold: t - coldBand - 1, sinceChange: 100) == 4),
        ("step down waits for settle",
            NextLevel(5, cap: 5, target: t, cold: t - coldBand - 1, sinceChange: stepDownSettle - 1) == 5),
        ("warm plate steps up one level", NextLevel(1, cap: 5, target: t, cold: t + coldBand + 1, sinceChange: 100) == 2),
        ("step up waits for settle",
            NextLevel(1, cap: 5, target: t, cold: t + coldBand + 1, sinceChange: stepUpSettle - 1) == 1),
        ("step up stops at cap", NextLevel(2, cap: 2, target: t, cold: t + coldBand + 1, sinceChange: 100) == 2),
        ("plate inside band holds", NextLevel(3, cap: 5, target: t, cold: t, sinceChange: 100) == 3),
        ("cap drop lowers level after dwell", NextLevel(5, cap: 0, target: t, cold: t, sinceChange: 100) == 0),
        ("warm plate restarts at c1", NextLevel(0, cap: 5, target: t, cold: t + fastRampGap + 1, sinceChange: 100) == 1),
        ("fan activity lasts the post-cool window", FanActive(spinning: true, sinceSpin: 0)
            && FanActive(spinning: false, sinceSpin: postCoolSeconds - 1) && !FanActive(spinning: false, sinceSpin: postCoolSeconds + 1)),
        ("deep cooling lowers the plate target by the full depth", ColdTarget(deep: true) == t - coldDepth && ColdTarget(deep: false) == t),
        ("flat die predicts itself", PredictDie([50, 50, 50, 50], dt: 1) == 50),
        ("rising die is extrapolated by the lead time", abs(PredictDie([50, 51, 52, 53], dt: 1) - (53 + leadSeconds)) < 1e-9),
        ("falling die is not extrapolated", PredictDie([53, 52, 51, 50], dt: 1) == 50),
        ("slope is per second at any tick", abs(Slope([50, 50.5, 51, 51.5], dt: 0.5) - 1) < 1e-9),
        ("Mac fan share spans min..max rpm", FanFraction([Float(fanMinRPM)]) == 0
            && FanFraction([Float(fanMaxRPM)]) == 1 && FanFraction([0, 0]) == nil),
        ("10 C plate condenses above 39 %RH at 25 C", abs(CondensingRH(surface: 10, room: 25) - 38.8) < 0.5),
        ("telemetry frame parses", ParseTelemetry([0x8B, 0x06, 0x20, 0x00, 0xF6, 0x2D, 0x58, 0x11, 0x14, 0x00, 0x00])
            .map { $0 == (-10, 45, 4440, 20) } == true),
        ("5 Pro frame rejected", ParseTelemetry([0x89, 0x06, 0x20, 0x00, 0, 0, 0, 0, 0, 0, 0]) == nil),
        ("telemetry watts identify the level", (0...maxLevel).allSatisfy { LevelForWatts(levelWatts[$0]) == $0 }
            && LevelForWatts(24) == 4 && LevelForWatts(1) == 0),
        ("fresh matching telemetry confirms a level",
            Confirms(level: 3, sentAt: Date(timeIntervalSince1970: 0), telemetryAt: Date(timeIntervalSince1970: 2), watts: 18)),
        ("telemetry right after the command does not confirm",
            !Confirms(level: 3, sentAt: Date(timeIntervalSince1970: 0), telemetryAt: Date(timeIntervalSince1970: 0.2), watts: 18)),
        ("off is confirmed only at exactly 0 W",
            !Confirms(level: 0, sentAt: Date(timeIntervalSince1970: 0), telemetryAt: Date(timeIntervalSince1970: 2), watts: 3)
            && Confirms(level: 0, sentAt: Date(timeIntervalSince1970: 0), telemetryAt: Date(timeIntervalSince1970: 2), watts: 0)),
        ("telemetry contradicting the confirmed level is divergence",
            Diverged(applied: 3, pending: false, sinceSend: 5, watts: 0)),
        ("matching or early telemetry is not divergence",
            !Diverged(applied: 3, pending: false, sinceSend: 5, watts: 18) && !Diverged(applied: 3, pending: false, sinceSend: 0.2, watts: 0)
            && !Diverged(applied: 3, pending: true, sinceSend: 5, watts: 0) && !Diverged(applied: nil, pending: false, sinceSend: 5, watts: 0)),
        ("a late frame showing another level does not confirm",
            !Confirms(level: 0, sentAt: Date(timeIntervalSince1970: 0), telemetryAt: Date(timeIntervalSince1970: 2), watts: 25)),
        ("custom 5 frame bytes", ModeFrame(5) == Data([0x06, 0x05, 0x00, 0x00, 0x04, 0x05])),
        ("off frame bytes", ModeFrame(0) == Data([0x06, 0x05, 0x00, 0x00, 0xFB, 0x00])),
    ]
    for (name, ok) in checks {
        print(ok ? "PASS" : "FAIL", name)
    }
    return checks.allSatisfy { $0.1 }
}

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest() ? 0 : 1)
}

let watchdogMode = CommandLine.arguments.contains("--watchdog")
let watchdogFd: Int32 = 3
let cleanExitMark = UInt8(ascii: "c")
let heartbeatMark = UInt8(ascii: "h")
// The controller beats once a second from its run loop; this much silence means it is stalled, not just slow
let heartbeatTimeout: TimeInterval = 10

// The cooler keeps its last level after the BLE link drops (measured: still 18 W after a SIGKILL), so a
// detached copy of this binary waits on a pipe and turns it off unless the controller confirmed that itself.
func SpawnWatchdog() -> (pid: pid_t, fd: Int32)? {
    var fds: [Int32] = [0, 0]
    guard let path = Bundle.main.executablePath, pipe(&fds) == 0 else { return nil }
    // The child's dup2 actions run in order, so a source that is also a later target (the lock on fd 3, the pipe on 4)
    // would be overwritten first; sources moved to 10 and up can never collide with targets 3 and 4.
    let pipeSource = fcntl(fds[0], F_DUPFD_CLOEXEC, 10)
    let lockSource = fcntl(lockFd, F_DUPFD_CLOEXEC, 10)
    close(fds[0])
    defer {
        close(pipeSource)
        close(lockSource)
    }
    guard pipeSource >= 0, lockSource >= 0 else {
        close(fds[1])
        return nil
    }
    var actions: posix_spawn_file_actions_t?
    var attr: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, pipeSource, watchdogFd)
    posix_spawn_file_actions_adddup2(&actions, lockSource, lockChildFd)
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--watchdog"), nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
    argv.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    guard rc == 0 else {
        close(fds[1])
        return nil
    }
    _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
    return (pid, fds[1])
}

// Returns only when the controller died without writing the clean-exit mark
func WatchdogWait() {
    for sig in [SIGHUP, SIGINT, SIGTERM, SIGQUIT] {
        signal(sig, SIG_IGN)
    }
    var mark: UInt8 = 0
    var waitFd = pollfd(fd: watchdogFd, events: Int16(POLLIN), revents: 0)
    while true {
        let ready = poll(&waitFd, 1, Int32(heartbeatTimeout * 1000))
        if ready == 0 {
            return
        }
        if ready < 0 {
            if errno == EINTR {
                continue
            }
            return
        }
        let n = read(watchdogFd, &mark, 1)
        if n == 1 && mark == cleanExitMark {
            exit(0)
        }
        if n == 0 || (n < 0 && errno != EINTR) {
            return
        }
    }
}

var watchdog: (pid: pid_t, fd: Int32)?

func WatchdogAlive() -> Bool {
    guard let w = watchdog else { return false }
    return waitpid(w.pid, nil, WNOHANG) == 0
}

func Fatal(_ s: String) -> Never {
    Log(s)
    output.Flush(timeout: 1)
    exit(1)
}

// One controller per user: two fight over the cooler (seen on hardware, each undoing the other's level). The flock
// belongs to the open file description, which the watchdog inherits on fd lockChildFd, so the lock stays held without
// a gap from controller start until both it and its watchdog are gone; the kernel drops it with the last of them.
let lockPath = NSTemporaryDirectory() + "shark_cooler.lock"
let lockChildFd: Int32 = 4
var lockFd: Int32 = -1

func StampLock(_ fd: Int32, _ holder: String) {
    _ = ftruncate(fd, 0)
    let line = "\(getpid())\(holder)\n"
    _ = line.withCString { pwrite(fd, $0, strlen($0), 0) }
}

func TakeLock() -> Bool {
    let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return false
    }
    StampLock(fd, "")
    lockFd = fd
    return true
}

func LockHolder() -> String {
    ((try? String(contentsOfFile: lockPath, encoding: .utf8)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)
}

if watchdogMode {
    WatchdogWait()
    // Closing our end tells a still-running controller that this takeover owns the cooler now
    close(watchdogFd)
    StampLock(lockChildFd, ", a watchdog finishing a takeover")
} else {
    guard let dieNow = ReadDieMax() else {
        Fatal("no PMU tdie sensors readable, exiting")
    }
    guard TakeLock() else {
        Fatal("another shark_cooler is already running (pid \(LockHolder())), refusing to start")
    }
    watchdog = SpawnWatchdog()
    guard watchdog != nil else {
        Fatal("watchdog could not start, refusing to drive the cooler")
    }
    if !tuiMode {
        Log(String(format: "%d die sensors, die max now %.1f C, mac fan %@ rpm (range %.0f..%.0f)",
                   dieSensors.count, dieNow, FanText(MacFanRPM()), fanMinRPM, fanMaxRPM))
    }
}

let ctl = Controller()

if watchdogMode {
    ctl.paused = true
    let deadline = Date().addingTimeInterval(watchdogWait)
    ctl.onTick = {
        if ctl.applied == 0 || Date() > deadline {
            exit(ctl.applied == 0 ? 0 : 1)
        }
    }
    RunLoop.main.run()
}

// Beats from the main run loop, so a stalled controller goes silent and the watchdog takes over. Returns false once
// the watchdog has closed its end, which it does when it starts a takeover.
@discardableResult
func Heartbeat() -> Bool {
    guard let w = watchdog else { return false }
    var mark = heartbeatMark
    return write(w.fd, &mark, 1) == 1 || errno != EPIPE
}
let heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Heartbeat() }

// Runs before every control decision. Crash protection has to exist whenever the cooler may run, and a watchdog
// that is taking over must not be fought: hold the cooler off until it exits, then start a fresh one.
func GuardWatchdog() {
    let alive = WatchdogAlive()
    if alive && !Heartbeat() {
        if !ctl.holdOff {
            ctl.Event("watchdog took over, holding off until it finishes")
        }
        ctl.holdOff = true
        return
    }
    guard !alive else { return }
    if let w = watchdog {
        close(w.fd)
    }
    watchdog = SpawnWatchdog()
    let wasHeld = ctl.holdOff
    ctl.holdOff = watchdog == nil
    if !ctl.holdOff {
        ctl.Event("watchdog restarted")
    } else if !wasHeld {
        ctl.Event("watchdog lost and could not restart, cooler held off")
    }
}

var shuttingDown = false

func Draw() {
    guard !shuttingDown else { return }
    let size = TerminalSize()
    output.Frame("\u{1B}[H" + RenderFrame(ctl, width: size.cols, height: size.lines) + "\u{1B}[J")
}

// The cooler's own presets ignore the cold-plate target (smart reached 8 C at 14 W), so every exit sends off and
// polls until telemetry shows 0 W; without that confirmation the watchdog keeps trying after this process is gone.
func Shutdown() {
    guard !shuttingDown else { return }
    shuttingDown = true
    ctl.timer?.invalidate()
    ctl.paused = true
    ctl.level = 0
    ctl.applied = nil
    ctl.pending = nil
    ctl.ApplyLevel()
    let start = Date()
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
        let confirmed = ctl.applied == 0
        guard confirmed || !ctl.connected || Date().timeIntervalSince(start) > shutdownWait else {
            ctl.ApplyLevel()
            ctl.Send(pollFrame)
            return
        }
        t.invalidate()
        if tuiMode {
            TuiLeave()
        }
        let handOver = WatchdogAlive()
        if let w = watchdog, confirmed || !ctl.everConnected {
            var mark = cleanExitMark
            _ = write(w.fd, &mark, 1)
        }
        Log(confirmed ? "exit: cooler off (confirmed by telemetry)"
            : !ctl.everConnected ? "exit: cooler was never connected"
            : handOver ? "exit: cooler off NOT confirmed, watchdog retries for \(Int(watchdogWait)) s"
            : "exit: cooler off NOT confirmed and no watchdog, check the cooler")
        output.Flush(timeout: 1)
        _exit(0)
    }
}

// Asleep, nothing supervises the plate and the cooler keeps its last level when the link drops (measured), so sleep
// is held back until telemetry shows the cooler off, or shutdownWait passes
let systemCanSleep: UInt32 = 0xE000_0270
let systemWillSleep: UInt32 = 0xE000_0280
let systemHasPoweredOn: UInt32 = 0xE000_0300
var powerPort: io_connect_t = 0
var powerNotifyPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0

func PrepareForSleep(_ notification: Int) {
    ctl.sleeping = true
    ctl.Event("system going to sleep, turning the cooler off")
    ctl.level = 0
    ctl.applied = nil
    ctl.pending = nil
    ctl.ApplyLevel()
    let start = Date()
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
        let confirmed = ctl.applied == 0
        guard confirmed || Date().timeIntervalSince(start) > shutdownWait else {
            ctl.ApplyLevel()
            ctl.Send(pollFrame)
            return
        }
        t.invalidate()
        ctl.Event(confirmed ? "cooler off, sleep allowed" : "cooler off NOT confirmed, sleep allowed")
        IOAllowPowerChange(powerPort, notification)
    }
}

powerPort = IORegisterForSystemPower(nil, &powerNotifyPort, { _, _, message, argument in
    let notification = Int(bitPattern: argument)
    switch message {
    case systemCanSleep:
        IOAllowPowerChange(powerPort, notification)
    case systemWillSleep:
        PrepareForSleep(notification)
    case systemHasPoweredOn:
        ctl.sleeping = false
        ctl.Event("system awake")
    default:
        break
    }
}, &powerNotifier)
if let port = powerNotifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
}

var sources: [DispatchSourceProtocol] = []
for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { Shutdown() }
    src.resume()
    sources.append(src)
}

if tuiMode {
    TuiEnter()
    ctl.preTick = { GuardWatchdog() }
    ctl.onTick = { Draw() }
    signal(SIGWINCH, SIG_IGN)
    let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    winch.setEventHandler { Draw() }
    winch.resume()
    sources.append(winch)
    let keys = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    keys.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(STDIN_FILENO, &buf, buf.count)
        if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) {
            keys.cancel()
            Shutdown()
            return
        }
        for b in buf.prefix(max(n, 0)) {
            switch b {
            case UInt8(ascii: "+"), UInt8(ascii: "="):
                baseTarget = min(25, baseTarget + 1)
                ctl.Event("base target \(baseTarget) C")
            case UInt8(ascii: "-"), UInt8(ascii: "_"):
                baseTarget = max(5, baseTarget - 1)
                ctl.Event("base target \(baseTarget) C")
            case UInt8(ascii: "p"):
                ctl.paused.toggle()
                ctl.Event(ctl.paused ? "paused, cooler off" : "resumed")
            case UInt8(ascii: "q"):
                Shutdown()
            default:
                break
            }
        }
        Draw()
    }
    keys.resume()
    sources.append(keys)
    Draw()
} else {
    ctl.preTick = { GuardWatchdog() }
    ctl.onTick = {
        if output.broken {
            Shutdown()
        }
        Log(ctl.StatusLine())
    }
}
RunLoop.main.run()
