#!/usr/bin/env python3
"""Compile the actual renderer against inert state; never construct a BLE manager."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'shark_cooler.swift'
s = source.read_text()
prefix = s[:s.index('// Apple Silicon die sensors')]
state = s[s.index('    var rssi:'):s.index('    override init()')]
helpers = s[s.index('func FanFraction('):s.index('@discardableResult\nfunc WriteOut')]
# FanText is a pure formatter next to the sensor helpers.
start = s.index('func FanText(')
fan_text = s[start:s.index('\n}', start) + 2]
render = s[s.index('enum Ink {'):s.index('var savedTermios')]
harness = prefix + '\nlet fanMinRPM = 2317.0\nlet fanMaxRPM = 7826.0\n' + helpers + fan_text
harness += '\nclass Controller {\n' + state + '\nvar connected = false\nvar fan: Double? { FanFraction(fans) }\n}\n' + render
harness += r'''
func Plain(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
}
var failures = 0
func Check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
let c = Controller()
c.connected = true
c.telemetry = (12, 36, 4200, 18)
c.telemetryAt = Date()
c.level = 5
c.applied = nil
c.pending = (5, Date(), 1)
c.die = 49
c.diePredicted = 52
c.events = [(Date(), String(repeating: "event ", count: 40))]
let expanded = Plain(RenderFrame(c, width: 100, height: 28))
Check("pending command stays distinct from confirmation", expanded.contains("requested c5") && expanded.contains("confirmed --") && expanded.contains("PENDING"))
Check("telemetry age is visible", expanded.contains("telemetry") && expanded.contains("ago"))
Check("expanded view has event history", expanded.contains("RECENT EVENTS") && expanded.contains("event event"))
c.dieFault = true
let fault = Plain(RenderFrame(c, width: 100, height: 28))
Check("die fault is explicit", fault.contains("UNREADABLE"))
var bounded = true
for width in [1, 20, 60, 74, 80, 100, 140, 200] {
    for height in [1, 10, 17, 24, 28, 30, 40, 51] {
        let rows = Plain(RenderFrame(c, width: width, height: height)).components(separatedBy: "\r\n")
        bounded = bounded && rows.count <= height && rows.allSatisfy { $0.unicodeScalars.reduce(0) { $0 + max(0, Int(wcwidth_l(Int32($1.value), displayLocale))) } <= max(0, width - 1) }
    }
}
Check("all frames fit terminal without last-column wrap", bounded)
let footers = [17, 24, 28, 30, 40, 51].allSatisfy { height in
    [74, 80, 100, 128, 200].allSatisfy { width in
        Plain(RenderFrame(c, width: width, height: height)).contains("[q] off & quit")
    }
}
Check("controls survive all supported window sizes", footers)
c.telemetryAt = Date.distantPast
Check("stale plate readings are hidden", Plain(RenderFrame(c, width: 100, height: 28)).contains("cold --") && Plain(RenderFrame(c, width: 100, height: 28)).contains("STALE / UNKNOWN"))
var row = Row()
row.Add("abc", Ink.red)
row.Add("def", Ink.cyan)
Check("clipping preserves color and resets it", row.Fitted(width: 4).contains("\u{1B}[\(Ink.cyan)md\u{1B}[0m") && Plain(row.Fitted(width: 4)) == "abcd")
c.sleeping = true
Check("sleep state has priority", Plain(RenderFrame(c, width: 100, height: 28)).contains("SLEEP / OFF"))
let unicodeFrame = Plain(RenderFrame(c, width: 128, height: 51))
Check("square corners frame the dashboard", unicodeFrame.contains("┌") && unicodeFrame.contains("┘") && !unicodeFrame.contains("╭"))
Check("wide dashboard stays compact", unicodeFrame.components(separatedBy: "\r\n").count <= 33 && unicodeFrame.components(separatedBy: "\r\n").count > 24)
Check("temperature plots expose thresholds and axes", unicodeFrame.contains("COLD PLATE") && unicodeFrame.contains("MAC DIE") && unicodeFrame.contains("target") && unicodeFrame.contains("-120s"))
Check("bars keep Unicode blocks", Bar(0.5, width: 8).contains("█") && !Bar(0.5, width: 8).contains("#"))
var unicodeRow = Row()
unicodeRow.Add("冷板e\u{301}│")
Check("Unicode survives clipping at cell boundaries", Plain(unicodeRow.Fitted(width: 5)) == "冷板e\u{301}")
c.sleeping = false
c.dieFault = false
c.pending = nil
c.applied = 3
c.level = 3
c.deep = true
c.target = 6
c.telemetryAt = Date()
c.fans = [0, 0]
c.coldHistory = (0..<90).map { 18 - Double($0) / 10 }
c.dieHistory = (0..<90).map { 45 + sin(Double($0) / 8) * 4 }
c.fanHistory = (0..<90).map { $0 < 30 ? 2400 : 0 }
let sampleNow = Date()
c.chartHistory = (0..<120).map { i -> ChartSample in
    let cold: Double? = i > 48 && i < 58 ? nil : 10.0 + sin(Double(i) / 14.0) * 3.0
    let watts: Double = i < 50 ? 25 : i < 80 ? 8 : 14
    return ChartSample(at: sampleNow.addingTimeInterval(Double(i - 119)),
                cold: cold,
                die: 43 + sin(Double(i) / 18) * 8,
                fan: i < 40 ? 2400 : 0, watts: watts)
}
let gap = Plot([(sampleNow.addingTimeInterval(-100), 5), (sampleNow.addingTimeInterval(-10), 8)],
               width: 47, height: 4, now: sampleNow, range: 0...10, ink: Ink.cyan)
Check("history gaps remain empty", gap.allSatisfy { row in
    let middle = Array(row.plain)[20..<30]
    return middle.allSatisfy { $0 == " " }
})
let curve = Plot((0..<120).map { (sampleNow.addingTimeInterval(Double($0 - 119)), Double($0 % 20)) },
                 width: 47, height: 4, now: sampleNow, range: 0...20, ink: Ink.cyan)
Check("history uses Braille dots", curve.contains { $0.plain.unicodeScalars.contains { (0x2801...0x28FF).contains($0.value) } })
c.events = [(Date(), "TEST FIXTURE / synthetic display data"), (Date(), "set c3"), (Date(), "cooler connected")]
try! RenderFrame(c, width: 128, height: 51).write(toFile: "build/tui_preview.ansi", atomically: true, encoding: .utf8)
try! RenderFrame(c, width: 80, height: 24).write(toFile: "build/tui_preview_small.ansi", atomically: true, encoding: .utf8)
exit(failures == 0 ? 0 : 1)
'''
build = root / 'build'
build.mkdir(exist_ok=True)
(build / 'tui_render_test.swift').write_text(harness)
subprocess.run(['swiftc', '-O', '-warnings-as-errors', str(build / 'tui_render_test.swift'), '-o', str(build / 'tui_render_test')], check=True)
raise SystemExit(subprocess.run([str(build / 'tui_render_test')], cwd=root).returncode)
