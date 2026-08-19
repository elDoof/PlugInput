#!/bin/bash
#
# Removes PlugInput: the app, the HAL driver, and optionally the saved session.
#
# A HAL driver the user cannot remove is hostile — it keeps appearing in every audio menu on
# the machine forever — so this ships alongside the installer rather than being an afterthought.
# BlackHole ships one for exactly the same reason.
#
#   ./uninstall.sh          # remove the app and the driver, keep settings
#   ./uninstall.sh --all    # also delete the saved session (plugin chain, dial positions)
#
# What this deliberately does NOT touch:
#
#   - BlackHole. PlugInput's driver is a separately named bundle with its own bundle id and
#     UID, installed alongside whatever else is in /Library/Audio/Plug-Ins/HAL. Other software
#     on this machine points at BlackHole and must keep working. The path below is spelled out
#     in full and never globbed, so there is no way for this to widen.
#   - The microphone permission grant. macOS owns that; it disappears with the app.
set -euo pipefail

readonly APP_NAME="PlugInput"
readonly DRIVER="/Library/Audio/Plug-Ins/HAL/PlugInput.driver"
readonly SUPPORT="$HOME/Library/Application Support/PlugInput"

REMOVE_SETTINGS=false
case "${1:-}" in
    --all) REMOVE_SETTINGS=true ;;
    "")    ;;
    *)     echo "usage: $0 [--all]" >&2; exit 2 ;;
esac
readonly REMOVE_SETTINGS

# --- quit the app ---------------------------------------------------------------------------

# Quit rather than kill: `willTerminate` is what destroys the engine's private aggregate device,
# and skipping it leaves an orphan behind that clutters the user's audio settings and blocks a
# future start on the same UID.
if pgrep -x "$APP_NAME" > /dev/null; then
    echo "==> quitting $APP_NAME"
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -x "$APP_NAME" > /dev/null || break
        sleep 1
    done
    if pgrep -x "$APP_NAME" > /dev/null; then
        echo "    still running; forcing"
        killall -9 "$APP_NAME" 2>/dev/null || true
    fi
fi

# --- the app --------------------------------------------------------------------------------

APP_REMOVED=false
for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    if [[ -d "$candidate" ]]; then
        echo "==> removing $candidate"
        rm -rf "$candidate" 2>/dev/null \
            || sudo rm -rf "$candidate"
        APP_REMOVED=true
    fi
done
$APP_REMOVED || echo "==> no installed app found (skipping)"

# --- the driver -----------------------------------------------------------------------------

if [[ -d "$DRIVER" ]]; then
    echo "==> removing $DRIVER (requires an administrator password)"
    sudo rm -rf "$DRIVER"

    # coreaudiod has the driver loaded; it only lets go on restart. This blips every audio
    # device on the machine for a moment, which is expected and is what BlackHole's own
    # uninstaller does.
    echo "==> restarting coreaudiod"
    sudo killall -9 coreaudiod 2>/dev/null || true
    sleep 3
else
    echo "==> no driver installed at $DRIVER (skipping)"
fi

# --- settings -------------------------------------------------------------------------------

if $REMOVE_SETTINGS; then
    if [[ -d "$SUPPORT" ]]; then
        echo "==> removing saved session $SUPPORT"
        rm -rf "$SUPPORT"
    fi
elif [[ -d "$SUPPORT" ]]; then
    echo "==> keeping saved session ($SUPPORT) — use --all to delete it"
fi

# --- verify ---------------------------------------------------------------------------------

# Removal is verified rather than assumed: this project has a long history of operations that
# report success and change nothing.
echo
FAILED=false
if [[ -d "$DRIVER" ]]; then
    echo "!!! $DRIVER is still present" >&2
    FAILED=true
fi
# Captured, not piped: `system_profiler | grep -q` returns non-zero under `set -o pipefail`
# when grep exits first and SIGPIPEs it, and here that failure would read as "the device is
# gone" — reporting a clean uninstall while the device is still listed.
AUDIO_DEVICES="$(system_profiler SPAudioDataType 2>/dev/null || true)"
if grep -q "^ *PlugInput:" <<< "$AUDIO_DEVICES"; then
    echo "!!! 'PlugInput' still appears as an audio device — a restart will clear it" >&2
    FAILED=true
fi
if $FAILED; then
    exit 1
fi

echo "PlugInput has been removed."
echo "(BlackHole and any other HAL drivers were left untouched.)"
