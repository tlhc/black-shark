#!/usr/bin/env python3
"""Run production BLE callbacks against deterministic offline transport doubles."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'shark_cooler.swift'
s = source.read_text()
methods = s[s.index('    func ClearConnection()') if '    func ClearConnection()' in s else s.index('    func Scan()'):s.index('    @discardableResult\n    func Send')]
callbacks = s[s.index('    func centralManagerDidUpdateState'):s.index('    func peripheral(_ p: CBPeripheral, didReadRSSI')]
extra = s[s.index('    var writeChar:'):s.index('    var rssi:')]
harness = r'''
import Foundation
let serviceUUID = "service", notifyUUID = "notify", writeUUID = "write"
let CBAdvertisementDataLocalNameKey = "name"
let pollFrame = Data([5,6,32,0,0])
let connectionTimeout: TimeInterval = 10
let reconnectDelay: TimeInterval = 2
let telemetryMaxAge: TimeInterval = 10
struct Props: OptionSet { let rawValue: Int; static let notify = Props(rawValue: 1); static let indicate = Props(rawValue: 8); static let write = Props(rawValue: 2); static let writeWithoutResponse = Props(rawValue: 4) }
class CBCharacteristic { let uuid: String; var properties: Props; var isNotifying = false; var value: Data?; init(_ id: String, _ props: Props) { uuid = id; properties = props } }
class CBService { let uuid = serviceUUID; var characteristics: [CBCharacteristic]? }
class CBPeripheral { var delegate: AnyObject?; var services: [CBService]?; func discoverServices(_ ids: [String]) {} ; func discoverCharacteristics(_ ids: [String]?, for s: CBService) {} ; func setNotifyValue(_ flag: Bool, for c: CBCharacteristic) {} }
enum State: Int { case poweredOff, poweredOn }
class CBCentralManager { var delegate: AnyObject?; var state = State.poweredOn; var cancels = 0; var scans = 0; var connects = 0; var existing: [CBPeripheral] = []; init(delegate: AnyObject?, queue: Any?) { self.delegate = delegate }; func retrieveConnectedPeripherals(withServices: [String]) -> [CBPeripheral] { existing }; func scanForPeripherals(withServices: [String]?) { scans += 1 }; func stopScan() {}; func connect(_ p: CBPeripheral) { connects += 1 }; func cancelPeripheralConnection(_ p: CBPeripheral) { cancels += 1 } }
class Timer { static var all: [Timer] = []; var valid = true; let block: (Timer) -> Void; init(_ b: @escaping (Timer) -> Void) { block = b }; @discardableResult static func scheduledTimer(withTimeInterval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer { let t = Timer(block); all.append(t); return t }; func invalidate() { valid = false }; static func Fire() { let old = all; all = []; for t in old where t.valid { t.block(t) } } }
typealias Telemetry = (cold: Int, hot: Int, rpm: Int, watts: Int)
func ParseTelemetry(_ b: [UInt8]) -> Telemetry? {
    guard b.count >= 11, b[0] == 0x8B, b[1] == 0x06, b[2] == 0x20, b[3] == 0x00 else { return nil }
    return (Int(Int8(bitPattern: b[4])), Int(Int8(bitPattern: b[5])), Int(b[6]) | Int(b[7]) << 8, Int(b[8]))
}
func Confirms(level: Int, sentAt: Date, telemetryAt: Date, watts: Int) -> Bool { false }
func Diverged(applied: Int?, pending: Bool, sinceSend: TimeInterval, watts: Int) -> Bool { false }
func LevelName(_ n: Int) -> String { String(n) }
class Controller {
    var central: CBCentralManager!
    var cooler: CBPeripheral?
    var rssi: Int?
    var telemetry: Telemetry?
    var telemetryAt = Date.distantPast
    var applied: Int?
    var pending: (level: Int, sentAt: Date, tries: Int)?
    var everConnected = false
    var lastSentAt = Date.distantPast
    var level = 0
    var sleeping = false
    var connected: Bool { writeChar != nil }
    func ApplyLevel() { Send(Data()) }
    var sends = 0
    var events: [String] = []
    init() { central = CBCentralManager(delegate: self, queue: nil) }
    func Event(_ s: String) { events.append(s) }
    @discardableResult func Send(_ d: Data) -> Bool { sends += 1; return true }
'''
harness += extra + methods + callbacks + '\n}\n'
harness += 'var ctl = Controller()\nlet shutdownWait: TimeInterval = 8\nlet powerPort = 0\nfunc IOAllowPowerChange(_ port: Int, _ notification: Int) {}\n'
start = s.index('func PrepareForSleep(')
harness += s[start:s.index('\npowerPort = IORegisterForSystemPower', start)]
harness += r'''
var failures = 0
func Check(_ name: String, _ body: () -> Bool) { Timer.all = []; let ok = body(); print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
func Start() -> (Controller, CBPeripheral, CBCentralManager) { let c = Controller(); let p = CBPeripheral(); c.Attach(p); return (c,p,c.central) }
Check("startup scans and connects advertised cooler") { let c = Controller(); let m = c.central!; c.centralManagerDidUpdateState(m); let p = CBPeripheral(); c.centralManager(m,didDiscover:p,advertisementData:[CBAdvertisementDataLocalNameKey:"Black Shark 6MAX"],rssi:NSNumber(value:-50)); return m.scans == 1 && m.connects == 1 && c.cooler === p }
Check("retry resumes scan and connects again") { let (c,_,old) = Start(); Timer.Fire(); Timer.Fire(); let m = c.central!; c.centralManagerDidUpdateState(m); let p = CBPeripheral(); c.centralManager(m,didDiscover:p,advertisementData:[CBAdvertisementDataLocalNameKey:"Black Shark 6MAX"],rssi:NSNumber(value:-50)); return m !== old && m.scans == 1 && m.connects == 1 && c.cooler === p }
Check("retry attaches existing shared connection") { let (c,p,old) = Start(); Timer.Fire(); Timer.Fire(); let m = c.central!; m.existing = [p]; c.centralManagerDidUpdateState(m); return m !== old && m.connects == 1 && m.scans == 0 && c.cooler === p }
Check("bluetooth power on resumes scan") { let (c,_,m) = Start(); m.state = .poweredOff; c.centralManagerDidUpdateState(m); m.state = .poweredOn; c.centralManagerDidUpdateState(m); return m.scans == 1 }
Check("late untracked connection is cancelled after radio restart") { let (c,p,m) = Start(); m.state = .poweredOff; c.centralManagerDidUpdateState(m); m.state = .poweredOn; c.centralManagerDidUpdateState(m); c.centralManager(m,didConnect:p); return m.cancels == 1 && c.cooler == nil && m.scans == 1 }
Check("untracked connection cannot replace active attempt") { let (c,p,m) = Start(); c.centralManager(m,didConnect:CBPeripheral()); return m.cancels == 1 && c.cooler === p }
Check("connect timeout cancels and retries") { let (c,_,old) = Start(); Timer.Fire(); Timer.Fire(); return old.cancels == 1 && c.central !== old }
Check("service timeout recovers") { let (c,p,old) = Start(); c.centralManager(old, didConnect:p); Timer.Fire(); Timer.Fire(); return old.cancels == 1 && c.central !== old }
Check("missing service recovers") { let (c,p,old) = Start(); c.centralManager(old,didConnect:p); p.services = []; c.peripheral(p,didDiscoverServices:nil); Timer.Fire(); return old.cancels == 1 }
Check("missing notify characteristic recovers") { let (c,p,old) = Start(); c.centralManager(old,didConnect:p); let s = CBService(); p.services = [s]; c.peripheral(p,didDiscoverServices:nil); s.characteristics = [CBCharacteristic(writeUUID,.write)]; c.peripheral(p,didDiscoverCharacteristicsFor:s,error:nil); return old.cancels == 1 && c.writeChar == nil }
Check("bluetooth off clears stale connection") { let (c,p,old) = Start(); c.writeChar = CBCharacteristic(writeUUID,.write); old.state = .poweredOff; c.centralManagerDidUpdateState(old); return c.writeChar == nil && c.cooler == nil && p.delegate == nil }
Check("late connection callback ignored") { let (c,p,old) = Start(); Timer.Fire(); Timer.Fire(); c.centralManager(old,didConnect:p); return c.cooler == nil && c.central !== old }
func Characteristics() -> (Controller, CBPeripheral, CBCentralManager, CBCharacteristic) {
    let (c,p,old) = Start()
    c.centralManager(old,didConnect:p)
    let s = CBService(); p.services = [s]
    c.peripheral(p,didDiscoverServices:nil)
    let n = CBCharacteristic(notifyUUID,.notify)
    s.characteristics = [n,CBCharacteristic(writeUUID,.write)]
    c.peripheral(p,didDiscoverCharacteristicsFor:s,error:nil)
    return (c,p,old,n)
}
Check("characteristic timeout recovers") { let (c,p,old) = Start(); c.centralManager(old,didConnect:p); p.services = [CBService()]; c.peripheral(p,didDiscoverServices:nil); Timer.Fire(); return old.cancels == 1 }
Check("subscription timeout recovers") { let (_,_,old,_) = Characteristics(); Timer.Fire(); return old.cancels == 1 }
Check("retry is delayed") { let (c,p,old) = Start(); c.centralManager(old,didFailToConnect:p,error:nil); return c.central === old && old.scans == 0 && c.cooler == nil }
Check("offline state blocks scan") { let c = Controller(); c.central.state = .poweredOff; c.Scan(); return c.central.scans == 0 }
Check("discovery error recovers") { let (c,p,old) = Start(); c.centralManager(old,didConnect:p); p.services = [CBService()]; c.peripheral(p,didDiscoverServices:NSError(domain:"test",code:1)); return old.cancels == 1 }
Check("indicate characteristic remains supported") { let (c,p,old) = Start(); c.centralManager(old,didConnect:p); let s = CBService(); p.services = [s]; c.peripheral(p,didDiscoverServices:nil); s.characteristics = [CBCharacteristic(notifyUUID,.indicate),CBCharacteristic(writeUUID,.write)]; c.peripheral(p,didDiscoverCharacteristicsFor:s,error:nil); return old.cancels == 0 && c.writeChar != nil }
Check("ready characteristics alone do not finish setup") { let (c,_,_,_) = Characteristics(); return !c.events.contains("connected") }
'''
if 'didUpdateNotificationStateFor' in callbacks:
    harness += r'''
Check("sleep without writable link still recovers") { let (c,_,m) = Start(); ctl = c; PrepareForSleep(1); Timer.Fire(); return m.cancels == 1 && c.cooler == nil }
Check("sleep off polling keeps writable setup link") { let (c,_,old,_) = Characteristics(); ctl = c; PrepareForSleep(1); Timer.Fire(); return c.sleeping && old.cancels == 0 && c.connected && c.sends >= 2 }
Check("wake restores setup timeout recovery") { let (c,_,old,_) = Characteristics(); ctl = c; PrepareForSleep(1); Timer.Fire(); let held = old.cancels == 0 && c.connected; c.sleeping = false; Timer.Fire(); return held && old.cancels == 1 && !c.connected }
Check("subscription error recovers") { let (c,p,old,n) = Characteristics(); c.peripheral(p,didUpdateNotificationStateFor:n,error:NSError(domain:"test",code:1)); return old.cancels == 1 }
Check("first telemetry timeout recovers") { let (c,p,old,n) = Characteristics(); n.isNotifying = true; c.peripheral(p,didUpdateNotificationStateFor:n,error:nil); Timer.Fire(); return old.cancels == 1 && c.sends == 1 }
Check("valid telemetry ends setup timer") { let (c,p,old,n) = Characteristics(); n.isNotifying = true; c.peripheral(p,didUpdateNotificationStateFor:n,error:nil); n.value = Data([0x8B,6,32,0,10,30,184,11,8,0,0]); c.peripheral(p,didUpdateValueFor:n,error:nil); Timer.Fire(); return old.cancels == 0 && c.events.contains("connected") && c.telemetry != nil }
Check("late subscription success leaves ready session alive") { let (c,p,old,n) = Characteristics(); n.isNotifying = true; n.value = Data([0x8B,6,32,0,10,30,184,11,8,0,0]); c.peripheral(p,didUpdateValueFor:n,error:nil); c.peripheral(p,didUpdateNotificationStateFor:n,error:nil); Timer.Fire(); return old.cancels == 0 }
Check("invalid telemetry does not finish setup") { let (c,p,old,n) = Characteristics(); n.isNotifying = true; c.peripheral(p,didUpdateNotificationStateFor:n,error:nil); n.value = Data([1]); c.peripheral(p,didUpdateValueFor:n,error:nil); Timer.Fire(); return old.cancels == 1 }
Check("old manager callbacks cannot clear new session") { let (c,p,old) = Start(); Timer.Fire(); Timer.Fire(); let q = CBPeripheral(); c.Attach(q); c.centralManager(old,didDisconnectPeripheral:p,error:nil); return c.cooler === q }
Check("old telemetry ignored after recovery") { let (c,p,_,n) = Characteristics(); n.isNotifying = true; n.value = Data([0x8B,6,32,0,10,30,184,11,8,0,0]); Timer.Fire(); c.peripheral(p,didUpdateValueFor:n,error:nil); return c.telemetry == nil }
'''
harness += '\nexit(failures == 0 ? 0 : 1)\n'
build = root / 'build'
build.mkdir(exist_ok=True)
path = build / 'ble_recovery_test.swift'
path.write_text(harness)
subprocess.run(['swiftc','-warnings-as-errors',str(path),'-o',str(build/'ble_recovery_test')],check=True)
raise SystemExit(subprocess.run([str(build/'ble_recovery_test')]).returncode)
