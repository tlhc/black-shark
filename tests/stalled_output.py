"""Regression: a TUI whose terminal is never read must still shut down on SIGTERM.

Runs the binary on a pty whose master side is never read, so the terminal buffer fills. The child must stay
alive through the fill phase, exit with status 0 after SIGTERM, and its watchdog child must be gone afterwards.
An optional shell command runs just before SIGTERM and its output is echoed (used to show the cooler is on).
Usage: python3 -I stalled_output.py BINARY RUN_SECONDS EXIT_DEADLINE_SECONDS [BEFORE_SIGTERM_COMMAND]
"""
import os
import pty
import signal
import subprocess
import sys
import time


def Alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


binary, run_seconds, deadline_seconds = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
before = sys.argv[4] if len(sys.argv) > 4 else None

pid, master = pty.fork()
if pid == 0:
    os.execv(binary, [binary])
start = time.time()
while time.time() - start < run_seconds:
    done, status = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        print("FAIL exited early, status %d" % status)
        sys.exit(1)
    time.sleep(0.5)
watchdogs = subprocess.run(["pgrep", "-P", str(pid), "-f", "--", "--watchdog"],
                           capture_output=True, text=True).stdout.split()
if before:
    print("before SIGTERM: " + subprocess.run(before, shell=True, capture_output=True, text=True).stdout.strip())
sent = time.time()
os.kill(pid, signal.SIGTERM)
while time.time() - sent < deadline_seconds:
    done, status = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        break
    time.sleep(0.2)
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    print("FAIL still running %.0f s after SIGTERM, killed" % deadline_seconds)
    sys.exit(1)
elapsed = time.time() - sent
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    print("FAIL abnormal exit after SIGTERM, status %d" % status)
    sys.exit(1)
time.sleep(3)
left = [w for w in watchdogs if Alive(int(w))]
if not watchdogs or left:
    print("FAIL watchdog " + ("never started" if not watchdogs else "still running: " + " ".join(left)))
    sys.exit(1)
print("PASS exited %.1f s after SIGTERM, watchdog %s gone" % (elapsed, " ".join(watchdogs)))
