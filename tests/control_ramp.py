#!/usr/bin/env python3
"""Exercise the production control law without BLE or sensor initialization."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'shark_cooler.swift'
s = source.read_text().split('// Apple Silicon die sensors', 1)[0]
s += r'''
let t = baseTarget
let checks: [(String, Bool)] = [
    ("warm restart enters c1", NextLevel(0, cap: 5, target: t, cold: t + 7, sinceChange: 3) == 1),
    ("large error rises one level at a time", (1...4).allSatisfy { NextLevel($0, cap: 5, target: t, cold: t + 7, sinceChange: 3) == $0 + 1 }),
    ("large error still waits three seconds", NextLevel(1, cap: 5, target: t, cold: t + 7, sinceChange: 2.9) == 1),
    ("near target rise waits five seconds", NextLevel(1, cap: 5, target: t, cold: t + 2, sinceChange: 4.9) == 1
        && NextLevel(1, cap: 5, target: t, cold: t + 2, sinceChange: 5) == 2),
    ("cold plate steps down after one second", NextLevel(4, cap: 5, target: t, cold: t - 2, sinceChange: 1) == 3),
    ("step down has a one second settle", NextLevel(4, cap: 5, target: t, cold: t - 2, sinceChange: 0.9) == 4),
    ("hard floor immediately shuts off", NextLevel(5, cap: 5, target: t, cold: t - 4, sinceChange: 0) == 0),
    ("unknown plate immediately shuts off", NextLevel(5, cap: 5, target: t, cold: nil, sinceChange: 0) == 0),
    ("inside band holds level", (0...5).allSatisfy { NextLevel($0, cap: 5, target: t, cold: t, sinceChange: 100) == $0 }),
]
for (name, ok) in checks { print(ok ? "PASS" : "FAIL", name) }
exit(checks.allSatisfy { $0.1 } ? 0 : 1)
'''
build = root / 'build'
build.mkdir(exist_ok=True)
(build / 'control_ramp_test.swift').write_text(s)
subprocess.run(['swiftc', '-O', '-warnings-as-errors', str(build / 'control_ramp_test.swift'), '-o', str(build / 'control_ramp_test')], check=True)
raise SystemExit(subprocess.run([str(build / 'control_ramp_test')]).returncode)
