#!/bin/bash
#
# Builds and installs the CoreAudio HAL driver that other apps select as "PlugInput".
#
# The driver is a renamed build of BlackHole. Renaming is not a runtime operation: a HAL
# device's name is the compile-time constant kDevice_Name, kAudioObjectPropertyName reports
# settable = false, and macOS keeps no user-level name override for HAL devices (only for
# aggregates, which is why Audio MIDI Setup can rename one and not the other). Building from
# source with our own name is the supported route, and BlackHole documents it.
#
#   ./make-driver.sh build     # build only, leaves the bundle in .build/driver
#   ./make-driver.sh install   # build, then install to /Library/Audio/Plug-Ins/HAL (needs sudo)
#
# Two things here are load-bearing:
#
# 1. THE VERSION IS PINNED TO v0.6.1 ON PURPOSE. A v0.7.1 build enumerates perfectly — right
#    name, right UID, opens at 2ch/48kHz — and then delivers exact digital silence. The
#    mechanism is in BlackHole.c: the input path zero-fills whenever
#    `gMute_Master_Value || lastOutputSampleTime - inIOBufferFrameSize < mInputTime.mSampleTime`,
#    and 0.7.1 fails that second clause. Measured: renamed 0.6.1 reads -14.0 dBFS on the same
#    two-process test where renamed 0.7.1 reads -120.0. Do not bump this without re-running
#    Spike/ and reading a real number.
#
# 2. THE UID IS DERIVED FROM THE NAME. BlackHole builds kDevice_UID as
#    kDriver_Name + "%ich" + "_UID", so DRIVER_NAME below decides the UID the app matches on
#    (VirtualMicrophone.driverUID). Changing one without the other silently stops the app
#    finding its own loopback.
#
# Licensing: BlackHole is GPL-3.0. Building this for your own machine is fine. DISTRIBUTING a
# renamed build makes it a derivative work — you owe recipients the source, and BlackHole's
# README asks distributors to contact Existential Audio. Resolve that before shipping.
set -euo pipefail

readonly DRIVER_NAME="PlugInput"
readonly BUNDLE_ID="com.pluginput.driver"
readonly DEVICE_NAME="PlugInput"
readonly SOURCE_TAG="v0.6.1"
readonly SOURCE_REPO="https://github.com/ExistentialAudio/BlackHole.git"
readonly LOCAL_SIGN_IDENTITY="PlugInput Local Signing"
readonly HAL_DIR="/Library/Audio/Plug-Ins/HAL"

ROOT="$(cd "$(dirname "$0")" && pwd)"
readonly ROOT
readonly SRC="$ROOT/.build/blackhole-src"
readonly OUT="$ROOT/.build/driver"

readonly MODE="${1:-install}"
if [[ "$MODE" != "build" && "$MODE" != "install" ]]; then
    echo "usage: $0 [build|install]" >&2
    exit 2
fi

# --- source ------------------------------------------------------------------------------

if [[ ! -d "$SRC/.git" ]]; then
    echo "==> cloning BlackHole"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet "$SOURCE_REPO" "$SRC"
fi

echo "==> checking out $SOURCE_TAG"
git -C "$SRC" fetch --quiet --tags origin
git -C "$SRC" checkout --quiet "$SOURCE_TAG"

# --- signing -----------------------------------------------------------------------------

# Identity selection, in the same priority order make-app.sh uses — and it has to be the same,
# because notarization validates *every* nested Mach-O in the package. A driver signed with the
# local leaf while the app carries a Developer ID passes every check on this machine and is then
# rejected by Apple minutes later, with nothing local having warned about it. This used to be a
# hardcoded constant with no Developer ID path at all, which made shipping impossible without
# editing the script.
#
#   1. $PLUGINPUT_SIGN_IDENTITY, so a release build can name an identity explicitly
#   2. a "Developer ID Application" identity, if the machine has one
#   3. the self-signed local leaf
#   4. ad-hoc — a genuine fallback here rather than a trap, unlike in the app: a HAL driver
#      needs no TCC grant, and a self-signed, un-notarized driver does load, which this project
#      verified rather than assumed. It cannot be notarized, though.
#
# Captured rather than piped: `security ... | grep -q` reports failure under `set -o pipefail`
# when grep exits first and `security` takes a SIGPIPE, which would silently sign the driver
# ad-hoc despite the identity being present.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"

SIGN_AS="${PLUGINPUT_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_AS" ]]; then
    SIGN_AS="$(sed -n 's/.*"\(Developer ID Application:.*\)"$/\1/p' <<< "$IDENTITIES" | head -1)"
fi
if [[ -z "$SIGN_AS" ]] && grep -q "$LOCAL_SIGN_IDENTITY" <<< "$IDENTITIES"; then
    SIGN_AS="$LOCAL_SIGN_IDENTITY"
fi
if [[ -z "$SIGN_AS" ]]; then
    echo "==> no signing identity found; signing ad-hoc (cannot be notarized)"
    SIGN_AS="-"
else
    echo "==> signing with '$SIGN_AS'"
fi
readonly SIGN_AS
SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_AS" DEVELOPMENT_TEAM="")
# Notarization rejects a signature with no secure timestamp, and xcodebuild does not add one on
# its own — the driver passed every local check and Apple returned "The signature does not
# include a secure timestamp" for both architectures. An ad-hoc signature cannot carry one, so
# this is only added for a real identity.
[[ "$SIGN_AS" != "-" ]] && SIGN_ARGS+=(OTHER_CODE_SIGN_FLAGS="--timestamp")
readonly SIGN_ARGS

# --- build -------------------------------------------------------------------------------

echo "==> building $DRIVER_NAME.driver"
rm -rf "$OUT"
(
    cd "$SRC"
    xcodebuild \
        -project BlackHole.xcodeproj \
        -configuration Release \
        -target BlackHole \
        CONFIGURATION_BUILD_DIR="$OUT" \
        PRODUCT_NAME="$DRIVER_NAME" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        ENABLE_HARDENED_RUNTIME=YES \
        "${SIGN_ARGS[@]}" \
        GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"'"$DRIVER_NAME"'\" kPlugIn_BundleID=\"'"$BUNDLE_ID"'\" kDevice_Name=\"'"$DEVICE_NAME"'\"' \
        build > "$ROOT/.build/driver-build.log" 2>&1 \
        || { echo "build failed; see .build/driver-build.log" >&2; exit 1; }
)

readonly BUNDLE="$OUT/$DRIVER_NAME.driver"
[[ -d "$BUNDLE" ]] || { echo "expected $BUNDLE to exist" >&2; exit 1; }
echo "    built $BUNDLE"

# The hardened runtime is required for notarization, on the driver as much as on the app —
# every publicly distributed HAL driver on this machine carries it (stock BlackHole and Zoom's
# both read flags=0x10000(runtime), both notarized under a Developer ID). ENABLE_HARDENED_RUNTIME
# above asks for it; this confirms xcodebuild honoured it, because a missing flag is invisible
# until Apple rejects the upload at the very end of the release process.
DRIVER_SIGNATURE="$(codesign -d --verbose=2 "$BUNDLE" 2>&1 || true)"
if grep -q "flags=.*runtime" <<< "$DRIVER_SIGNATURE"; then
    echo "    hardened runtime: yes"
else
    echo "!!! $BUNDLE is not signed with the hardened runtime; notarization would reject it" >&2
    exit 1
fi

if [[ "$MODE" == "build" ]]; then
    echo "==> done (not installed)"
    exit 0
fi

# --- install -----------------------------------------------------------------------------

# Restarting coreaudiod is how a HAL plug-in gets picked up; there is no lighter-weight signal
# and no API to ask for one. `launchctl kickstart -k` rather than `killall -9`, because a clean
# restart is markedly less likely to make macOS re-elect a default device — and the device it
# elects is the loopback that was just installed, which leaves every app following the system
# default listening to silence. `killall -9` is kept as a fallback for anything that refuses.
# This blips every audio device on the machine for a moment either way, which is expected and is
# what BlackHole's own install instructions do.
echo "==> installing to $HAL_DIR (requires an administrator password)"
sudo rm -rf "${HAL_DIR:?}/$DRIVER_NAME.driver"
sudo cp -R "$BUNDLE" "$HAL_DIR/"
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null \
    || sudo killall -9 coreaudiod

echo "==> waiting for coreaudiod"
sleep 3

# Captured, not piped — and here it matters more than anywhere else in this file.
# `system_profiler` emits a lot of output, so `grep -q` reliably exits before it finishes and
# kills it with SIGPIPE; under `set -o pipefail` that makes a successful install report
# "did not appear" and exit 1.
AUDIO_DEVICES="$(system_profiler SPAudioDataType 2>/dev/null || true)"
if grep -q "^ *$DEVICE_NAME:" <<< "$AUDIO_DEVICES"; then
    echo "==> '$DEVICE_NAME' is present as an audio device"
else
    echo "!!! '$DEVICE_NAME' did not appear. Check .build/driver-build.log" >&2
    exit 1
fi

cat <<EOF

Installed. '$DEVICE_NAME' is now selectable as a microphone in other apps.

Presence is not signal flow — this project has shipped a device that enumerated correctly and
carried silence. To measure it for real, with PlugInput running and a plugin loaded:

    cd Spike && ./.build/debug/PlugInputSpike listen 4 $DEVICE_NAME

Broadband well above -120.0 dBFS is the proof. Ignore the harness's RESULT: FAIL, which looks
for a 440Hz tone that a microphone does not emit, and give the engine a few seconds after
launch before listening.
EOF
