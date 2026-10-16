import CoreBluetooth
import Foundation

// Usage: mode_probe MMPP:secs ... | raw=HEX:secs   sends each step, then turns the cooler off
//        mode_probe --watch SECONDS                  polls only and never sends a mode, so the cooler is left as found
// MMPP is the mode and parameter byte of a 06 05 00 00 MM PP frame; telemetry is polled every second.
let serviceUUID = CBUUID(string: "0000A0A0-3C17-D293-8E48-14FE2E4DA212")
let pollFrame = Data([0x05, 0x06, 0x20, 0x00, 0x00])

func HexData(_ s: String) -> Data? {
    guard !s.isEmpty, s.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
        bytes.append(b)
        i = j
    }
    return Data(bytes)
}

typealias Step = (label: String, frame: Data, seconds: Double)

// Every argument must parse; a misplaced --watch, a typo or bad hex rejects the whole command instead of being
// skipped, so a request meant to be read-only can never fall through to sending a mode
func ParseArgs(_ args: [String]) -> (watch: Bool, steps: [Step])? {
    if args.contains("--watch") {
        guard args.count == 2, args[0] == "--watch", let secs = Double(args[1]) else { return nil }
        return (true, [("watch", pollFrame, secs)])
    }
    guard !args.isEmpty else { return nil }
    var steps: [Step] = []
    for arg in args {
        let parts = arg.split(separator: ":")
        guard parts.count == 2, let secs = Double(parts[1]) else { return nil }
        let spec = String(parts[0])
        if spec.hasPrefix("raw=") {
            guard let frame = HexData(String(spec.dropFirst(4))) else { return nil }
            steps.append((spec, frame, secs))
        } else {
            guard let modeParam = HexData(spec), modeParam.count == 2 else { return nil }
            steps.append((spec, Data([0x06, 0x05, 0x00, 0x00]) + modeParam, secs))
        }
    }
    return (false, steps)
}

func ProbeSelfTest() -> Bool {
    let checks: [(String, Bool)] = [
        ("watch polls only", ParseArgs(["--watch", "2"]).map { $0.watch && $0.steps.count == 1 && $0.steps[0].frame == pollFrame } == true),
        ("watch rejects a mode step", ParseArgs(["--watch", "0405:2"]) == nil),
        ("misplaced watch is rejected", ParseArgs(["0405:2", "--watch", "2"]) == nil),
        ("mode step builds a custom frame",
            ParseArgs(["0405:2"]).map { !$0.watch && $0.steps[0].frame == Data([0x06, 0x05, 0x00, 0x00, 0x04, 0x05]) } == true),
        ("raw step is passed through", ParseArgs(["raw=0506200000:2"]).map { $0.steps[0].frame == pollFrame } == true),
        ("bad hex is rejected", ParseArgs(["04z5:2"]) == nil && ParseArgs(["raw=050:2"]) == nil && ParseArgs(["040506:2"]) == nil),
        ("unparseable or missing arguments are rejected", ParseArgs(["0405:2", "junk"]) == nil && ParseArgs([]) == nil),
    ]
    for (name, ok) in checks {
        print(ok ? "PASS" : "FAIL", name)
    }
    return checks.allSatisfy { $0.1 }
}

let probeArgs = Array(CommandLine.arguments.dropFirst())
if probeArgs == ["--selftest"] {
    exit(ProbeSelfTest() ? 0 : 1)
}
guard let parsed = ParseArgs(probeArgs) else {
    print("usage: mode_probe MMPP:secs ... | raw=HEX:secs    or    mode_probe --watch SECONDS (polls only, never sends a mode)")
    exit(2)
}
let watchOnly = parsed.watch
let steps = parsed.steps

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var cooler: CBPeripheral?
    var writeChar: CBCharacteristic?
    var stepIndex = -1
    var stepStart = Date()
    let t0 = Date()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func Write(_ d: Data) {
        guard let p = cooler, let w = writeChar else { return }
        p.writeValue(d, for: w, type: .withoutResponse)
    }

    func NextStep() {
        stepIndex += 1
        guard stepIndex < steps.count else {
            if !watchOnly {
                Write(Data([0x06, 0x05, 0x00, 0x00, 0xFB, 0x00]))
            }
            print(watchOnly ? "done" : "done, cooler off")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return
        }
        stepStart = Date()
        Write(steps[stepIndex].frame)
        print(String(format: "%6.1f  >> %@  %@", Date().timeIntervalSince(t0), steps[stepIndex].label,
                     steps[stepIndex].frame.map { String(format: "%02X", $0) }.joined(separator: " ")))
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        if let p = c.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            cooler = p
            p.delegate = self
            c.connect(p)
        } else {
            c.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard let name = ad[CBAdvertisementDataLocalNameKey] as? String,
              name.lowercased().replacingOccurrences(of: " ", with: "").contains("6max") else { return }
        c.stopScan()
        cooler = p
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([serviceUUID])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let s = p.services?.first(where: { $0.uuid == serviceUUID }) { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = s.characteristics ?? []
        if let n = chars.first(where: { $0.uuid == CBUUID(string: "A002") }) { p.setNotifyValue(true, for: n) }
        writeChar = chars.first(where: { $0.uuid == CBUUID(string: "A001") })
        NextStep()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.stepIndex < steps.count else { return }
            self.Write(pollFrame)
            if Date().timeIntervalSince(self.stepStart) >= steps[self.stepIndex].seconds { self.NextStep() }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, stepIndex >= 0, stepIndex < steps.count else { return }
        let b = [UInt8](v)
        let hex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
        if b.count >= 9 && b[0] == 0x8B && b[1] == 0x06 {
            print(String(format: "%6.1f  %-10@ cold %3d  hot %3d  rpm %5d  power %3d W   [%@]", Date().timeIntervalSince(t0),
                         steps[stepIndex].label, Int(Int8(bitPattern: b[4])), Int(Int8(bitPattern: b[5])),
                         Int(b[6]) | Int(b[7]) << 8, Int(b[8]), hex))
        } else {
            print(String(format: "%6.1f  %-10@ other frame [%@]", Date().timeIntervalSince(t0), steps[stepIndex].label, hex))
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let probe = Probe()
RunLoop.main.run(until: Date().addingTimeInterval(steps.reduce(15) { $0 + $1.seconds }))
