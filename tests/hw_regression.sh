#!/bin/bash
# Hardware regression for shark_cooler: needs the MagCooler 6 Max powered and not held by the phone app.
# Usage: tests/hw_regression.sh [binary]   (default build/shark_cooler); prints PASS/FAIL per case.
# Every process it inspects or signals is one this run started, tracked by PID.
cd "$(dirname "$0")/.." || exit 1
bin=${1:-build/shark_cooler}
probe=build/mode_probe
fails=0
swiftc -O tests/mode_probe.swift -o $probe || exit 1
clang -O2 tests/fd_watch.c -o build/fd_watch || exit 1

Load() { for i in 1 2 3 4 5 6; do timeout "$1" bash -c 'while :; do :; done' & done; }
# Cooler power, over the existing link when one is up; --watch only polls and never sends a mode
Watts() { $probe --watch 2 2>&1 | sed -n 's/.*power *\([0-9]*\) W.*/\1/p' | head -1; }
WatchdogOf() { pgrep -P "$1" -f -- '--watchdog' | head -1; }
# A child that exits while its parent is stopped stays a zombie until reaped, which counts as gone
Gone() { [ -n "$1" ] && { ! kill -0 "$1" 2>/dev/null || [ "$(ps -o stat= -p "$1" | cut -c1)" = Z ]; }; }
Check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1: $3"; fails=$((fails + 1)); fi; }
Settle() { wait 2>/dev/null; sleep "${1:-4}"; }

# A: levels confirmed by telemetry, SIGTERM exit confirmed, watchdog stands down
Load 26; $bin > build/hw_a.log 2>&1 & pid=$!; sleep 3; wd=$(WatchdogOf $pid); sleep 19
kill -TERM $pid; wait $pid; sleep 2
Gone "$wd" && grep -qE 'set c[1-5]' build/hw_a.log && grep -q 'exit: cooler off (confirmed by telemetry)' build/hw_a.log \
    && Check A ok || Check A bad "wd=$wd $(grep -E 'set |exit' build/hw_a.log | tr '\n' ' ')"
Settle

# B: closing the terminal (SIGHUP) with the cooler on leaves it off
sess=hwb-$$; Load 24; tmux new-session -d -s $sess -x 80 -y 24 "$PWD/$bin"; sleep 3
pane=$(tmux list-panes -t $sess -F '#{pane_pid}'); ctl=$(pgrep -P "$pane" -f -- "$bin\$" | head -1); ctl=${ctl:-$pane}
wd=$(WatchdogOf $ctl); sleep 13; before=$(Watts)
tmux kill-session -t $sess; sleep 6; after=$(Watts)
[ "${before:-0}" -gt 0 ] && Gone "$ctl" && Gone "$wd" && [ "$after" = 0 ] \
    && Check B ok || Check B bad "before=$before after=$after ctl=$ctl wd=$wd"
Settle

# C: SIGKILL of the controller with the cooler on, the watchdog turns it off
Load 22; $bin > build/hw_c.log 2>&1 & pid=$!; sleep 3; wd=$(WatchdogOf $pid); sleep 12; before=$(Watts)
kill -9 $pid; wait $pid 2>/dev/null; sleep 8; after=$(Watts)
[ "${before:-0}" -gt 0 ] && Gone "$wd" && [ "$after" = 0 ] && Check C ok || Check C bad "before=$before after=$after wd=$wd"
Settle

# D: a killed watchdog is restarted within a tick
$bin > build/hw_d.log 2>&1 & pid=$!; sleep 4; w1=$(WatchdogOf $pid); [ -n "$w1" ] && kill -9 "$w1"; sleep 3
w2=$(WatchdogOf $pid); kill -TERM $pid; wait $pid; sleep 2
[ -n "$w1" ] && [ -n "$w2" ] && [ "$w1" != "$w2" ] && Gone "$w2" && grep -q 'watchdog restarted' build/hw_d.log \
    && Check D ok || Check D bad "before=$w1 after=$w2"
Settle 2

# E: no watchdog possible (pipe fails) means the controller refuses to run
(ulimit -n 4; exec timeout 10 $bin) > build/hw_e.log 2>&1; rc=$?
[ $rc = 1 ] && grep -q 'refusing to drive the cooler' build/hw_e.log && Check E ok || Check E bad "rc=$rc $(head -1 build/hw_e.log)"
Settle 2

# F: a TUI whose terminal is never read still shuts down on SIGTERM with the cooler on, and leaves it off
Load 32
r=$(python3 -I tests/stalled_output.py "$bin" 18 12 "$probe --watch 2 | sed -n 's/.*power *\([0-9]*\) W.*/\1/p' | head -1")
sleep 3; after=$(Watts); before=$(printf '%s\n' "$r" | sed -n 's/^before SIGTERM: //p')
case "$r" in *PASS*) [ "${before:-0}" -gt 0 ] && [ "$after" = 0 ] && Check F ok || Check F bad "before=$before after=$after";;
             *) Check F bad "$(printf '%s' "$r" | tr '\n' ' ')";; esac
Settle

# G: a stalled controller (SIGSTOP) is replaced by the watchdog, which turns the cooler off; after SIGCONT the
# controller starts a new watchdog and keeps control
Load 75; $bin > build/hw_g.log 2>&1 & pid=$!; sleep 3; wd=$(WatchdogOf $pid); sleep 17; before=$(Watts)
kill -STOP $pid; sleep 18; during=$(Watts); gone=$(Gone "$wd" && echo yes)
kill -CONT $pid; sleep 12; kill -TERM $pid; wait $pid
[ "${before:-0}" -gt 0 ] && [ "$during" = 0 ] && [ "$gone" = yes ] && grep -q 'watchdog restarted' build/hw_g.log \
    && grep -q 'exit: cooler off (confirmed by telemetry)' build/hw_g.log \
    && Check G ok || Check G bad "before=$before during=$during wdGone=$gone $(grep -E 'watchdog|exit' build/hw_g.log | tr '\n' ' ')"
Settle 2

# H: the controller resumes while the takeover is still running; it must hold off (no powered level) until the
# takeover watchdog exits and a new one is running. Resume the moment the watchdog's fd 3 stops being the pipe.
Load 70; $bin > build/hw_h.log 2>&1 & pid=$!; sleep 3; wd=$(WatchdogOf $pid); sleep 17
kill -STOP $pid; build/fd_watch "$wd" 3 20000
kill -CONT $pid; sleep 15; kill -TERM $pid; wait $pid
fought=$(awk '/watchdog took over/ {hold = 1} /watchdog restarted/ {hold = 0} hold && /set c[1-5]/ {n++} END {print n + 0}' build/hw_h.log)
grep -q 'watchdog took over' build/hw_h.log && grep -q 'watchdog restarted' build/hw_h.log && [ "$fought" = 0 ] \
    && Check H ok || Check H bad "fought=$fought $(grep -E 'watchdog|set ' build/hw_h.log | tr '\n' ' ')"
Settle 2

# I: one controller at a time: a second one is refused, and so is one started right after a crash while the
# crashed controller's watchdog is still taking over; once that takeover ends a new controller starts
$bin > build/hw_i1.log 2>&1 & pid=$!; sleep 4
$bin > build/hw_i2.log 2>&1; r2=$?
kill -9 $pid; wait $pid 2>/dev/null
$bin > build/hw_i3.log 2>&1; r3=$?
sleep 12
$bin > build/hw_i4.log 2>&1 & p4=$!; sleep 4; alive4=$(kill -0 $p4 2>/dev/null && echo yes)
kill -TERM $p4; wait $p4
[ $r2 = 1 ] && grep -q 'already running' build/hw_i2.log && [ $r3 = 1 ] && grep -q 'already running' build/hw_i3.log \
    && [ "$alive4" = yes ] && Check I ok || Check I bad "r2=$r2 r3=$r3 alive4=$alive4"
Settle 2

echo "failures: $fails"
exit $fails
