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
readonly SIGN_IDENTITY="PlugInput Local Signing"
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

# Same reasoning as make-app.sh: a stable leaf keeps the code requirement stable. A HAL driver
# needs no TCC grant, so ad-hoc is a genuine fallback here rather than a trap — a self-signed,
# un-notarized driver does load, which this project verified rather than assumed.
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="")
    echo "==> signing with '$SIGN_IDENTITY'"
else
    SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
    echo "==> '$SIGN_IDENTITY' not found; signing ad-hoc"
fi
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
        "${SIGN_ARGS[@]}" \
        GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"'"$DRIVER_NAME"'\" kPlugIn_BundleID=\"'"$BUNDLE_ID"'\" kDevice_Name=\"'"$DEVICE_NAME"'\"' \
        build > "$ROOT/.build/driver-build.log" 2>&1 \
        || { echo "build failed; see .build/driver-build.log" >&2; exit 1; }
)

readonly BUNDLE="$OUT/$DRIVER_NAME.driver"
[[ -d "$BUNDLE" ]] || { echo "expected $BUNDLE to exist" >&2; exit 1; }
echo "    built $BUNDLE"

if [[ "$MODE" == "build" ]]; then
    echo "==> done (not installed)"
    exit 0
fi

# --- install -----------------------------------------------------------------------------

# coreaudiod must be restarted for a HAL plug-in to load; there is no lighter-weight signal.
# This blips every audio device on the machine for a moment, which is expected, and is exactly
# what BlackHole's own install instructions do.
echo "==> installing to $HAL_DIR (requires an administrator password)"
sudo rm -rf "${HAL_DIR:?}/$DRIVER_NAME.driver"
sudo cp -R "$BUNDLE" "$HAL_DIR/"
sudo killall -9 coreaudiod

echo "==> waiting for coreaudiod"
sleep 3

if system_profiler SPAudioDataType 2>/dev/null | grep -q "^ *$DEVICE_NAME:"; then
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
