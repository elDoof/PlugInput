#!/bin/bash
#
# Reproduces "the PlugInput device goes silent after repeated app restarts" and produces a
# table, so the next person argues with a number instead of with the source.
#
# Run it as:  sudo -v && ./Tools/repro-driver-silence.sh [cycles]
#
# WHAT IT MEASURES. Each cycle launches the app with PLUGINPUT_TEST_TONE=1 — a 440Hz tone of
# known amplitude at the head of the chain, so no microphone, no plugin and no TCC decision is
# involved and the whole *output* leg is still exercised. A separate process then reads the
# PlugInput device. A healthy cycle reads around -17 dBFS; the failure reads exactly -120.0.
#
# THREE THINGS THAT MAKE THIS MEASUREMENT LIE, all controlled for here:
#
# 1. The reader goes out of sync on its own. Opening and closing the virtual device repeatedly
#    leaves later readers on exact digital silence for tens of seconds before recovering with
#    nothing changed (gotcha #22). This experiment opens and closes it by design, so it would
#    manufacture its own false positive. SETTLE_SECONDS between cycles is the control, and the
#    app's own `output peak` is captured alongside every reading: peak moving while the listener
#    reads -120.0 means the READER is out of sync, not the driver.
# 2. A scripted run can pass by testing nothing. A ten-cycle quit-crash test once reported zero
#    crashes because the app had overwritten the seeded session and every launch ran with no
#    plugins at all. So every cycle asserts `engine started` appeared in the log for THAT launch
#    before its reading is recorded, and a cycle that did not start is reported as such rather
#    than counted as silence.
# 3. Reading too early looks exactly like the bug. The engine needs a few seconds after launch.
#
# The session file holds a real setup, and a running app rewrites it on a 30s autosave, so it is
# backed up and restored around the run.
set -euo pipefail

readonly CYCLES="${1:-6}"
readonly SETTLE_SECONDS=30     # let the reader's re-sync clear between cycles (trap 1)
readonly WARMUP_SECONDS=8      # let the engine come up before listening (trap 3)
readonly LISTEN_SECONDS=4

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT
readonly APP="/Applications/PlugInput.app/Contents/MacOS/PlugInput"
readonly SPIKE="$ROOT/Spike/.build/debug/PlugInputSpike"
readonly SESSION="$HOME/Library/Application Support/PlugInput/session.json"
readonly BACKUP="$SESSION.repro-backup"

for f in "$APP" "$SPIKE"; do
    [[ -x "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

# The device-state probe is a single source file compiled on demand, so there is nothing to keep
# in sync and nothing committed that a rebuild could contradict.
readonly DEVSTATE="$ROOT/.build/devstate"
if [[ ! -x "$DEVSTATE" || "$ROOT/Tools/devstate.swift" -nt "$DEVSTATE" ]]; then
    echo "==> building the device-state probe"
    mkdir -p "$ROOT/.build"
    swiftc -O -o "$DEVSTATE" "$ROOT/Tools/devstate.swift"
fi

# The listener refuses to run at all when system output is routed into a loopback device, and it
# says so on stderr and exits 1 — which this script would otherwise record as six clean readings
# of silence. A run that cannot measure must not look like a run that measured nothing.
if ! "$SPIKE" listen 1 PlugInput >/dev/null 2>&1; then
    PRECHECK="$("$SPIKE" listen 1 PlugInput 2>&1 | head -4)"
    if grep -qi "system output is currently set to" <<< "$PRECHECK"; then
        echo "!!! the listener cannot run in this configuration, so nothing would be measured:" >&2
        echo "$PRECHECK" | sed 's/^/    /' >&2
        echo "    Move system output to speakers or headphones and run this again." >&2
        exit 1
    fi
fi

quit_app() { osascript -e 'quit app "PlugInput"' 2>/dev/null || true; sleep 2; }

cleanup() {
    quit_app
    [[ -f "$BACKUP" ]] && mv -f "$BACKUP" "$SESSION"
    echo "restored $SESSION"
}
trap cleanup EXIT

echo "==> quitting any running app, backing up the session"
quit_app
cp "$SESSION" "$BACKUP"

# Seed a running engine. The app is quit, so this will not be overwritten underneath us.
python3 - "$SESSION" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["isRunning"] = True
# Monitoring off, for two reasons: six cycles of a 440Hz tone through the operator's speakers is
# unkind, and the monitor leg is a second subdevice in the aggregate (gotcha #24) that this
# experiment has no reason to vary.
d["isMonitorEnabled"] = False
json.dump(d, open(p, "w"), indent=2)
print("    seeded isRunning=true, isMonitorEnabled=false")
PY

# A fresh coreaudiod is the clean baseline: the driver's suspect state lives in that process
# and nothing else resets it. It needs root, and `sudo` cannot prompt without a terminal — so
# this is attempted non-interactively and SKIPPED rather than fatal, because a dirty-baseline
# run still shows the progression and is worth having. What must never happen is a run that
# quietly reports a dirty baseline as a clean one, so the state is printed either way.
BASELINE="fresh coreaudiod"
if sudo -n launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
    echo "==> restarted coreaudiod for a clean driver baseline"
    sleep 5
else
    BASELINE="NOT RESET — coreaudiod has been up for $(ps -o etime= -p "$(pgrep -x coreaudiod | head -1)" 2>/dev/null | tr -d ' ')"
    echo "==> could not restart coreaudiod (needs root, and sudo cannot prompt here)."
    echo "    Continuing WITHOUT a clean baseline. If the failure is already present, cycle 1"
    echo "    will show it; for the controlled version run this from a real Terminal window:"
    echo "        sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
fi
readonly BASELINE

echo
echo "baseline: $BASELINE"
printf '\n%-6s %-14s %-12s %-22s %s\n' CYCLE "ENGINE" "DEVICE" "LISTENER(dBFS)" "APP output peak"
printf '%s\n' "------------------------------------------------------------------------------"

for (( c = 1; c <= CYCLES; c++ )); do
    echo "--- cycle $c: launching" >&2
    launched_at="$(date '+%Y-%m-%d %H:%M:%S')"
    PLUGINPUT_TEST_TONE=1 "$APP" >/dev/null 2>&1 &
    sleep "$WARMUP_SECONDS"

    # Trap 2: did THIS launch actually start an engine?
    started="$( { /usr/bin/log show --start "$launched_at" --info \
        --predicate 'subsystem == "com.pluginput.app"' --style compact 2>/dev/null \
        | grep -c 'engine started'; } || true )"
    [[ -z "$started" ]] && started=0
    engine=$([[ "$started" -gt 0 ]] && echo "started" || echo "NOT-STARTED")

    # The device's own view: 1 here with a client attached is normal; the leak shows up later.
    devstate="$("$DEVSTATE" PlugInput 2>/dev/null | awk -F': *' '/IsRunning/{print $2}' | awk '{print $1}')"

    # `|| true` is load-bearing twice over, and its absence killed the first run of this script
    # in cycle 1. The Spike harness exits non-zero whenever it prints RESULT: FAIL — which it
    # does on every microphone-shaped reading, because it is looking for a Phase 0 440Hz tone —
    # and `grep` exits 1 when it matches nothing. Under `set -o pipefail` either one aborts the
    # whole run. The FAIL line is explicitly not the signal here; the dBFS number is.
    reading="$( { cd "$ROOT/Spike" && ./.build/debug/PlugInputSpike listen "$LISTEN_SECONDS" PlugInput 2>&1 \
        | grep -oE '\-?[0-9]+\.[0-9]+ dBFS' | tail -1; } || true )"
    [[ -z "$reading" ]] && reading="(no reading)"

    # Cross-check: the app's own output meter for the same moment (trap 1).
    peak="$( { /usr/bin/log show --start "$launched_at" --info \
        --predicate 'subsystem == "com.pluginput.app"' --style compact 2>/dev/null \
        | grep -oE 'output peak [0-9.]+' | tail -1; } || true )"
    [[ -z "$peak" ]] && peak="(none logged)"

    printf '%-6s %-14s %-12s %-22s %s\n' "$c" "$engine" "${devstate:-?}" "$reading" "$peak"

    quit_app
    [[ "$c" -lt "$CYCLES" ]] && sleep "$SETTLE_SECONDS"
done

echo
echo "==> with the app quit, the device should read IsRunning: 0."
echo "    A 1 here is a leaked StartIO — the refcount BlackHole.c keeps at line 4329/4370,"
echo "    which only a coreaudiod restart clears, and is the leading suspect."
"$DEVSTATE" PlugInput || true
