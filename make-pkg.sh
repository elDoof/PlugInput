#!/bin/bash
#
# Builds the distributable installer: PlugInput.pkg, containing the app and the HAL driver.
#
#   ./make-pkg.sh              # build the .pkg (signs it if a Developer ID Installer exists)
#   ./make-pkg.sh --notarize   # also submit to Apple, wait, and staple the ticket
#
# Why a .pkg and not a .dmg with a drag-to-Applications window: the HAL driver has to land in
# /Library/Audio/Plug-Ins/HAL, which the user cannot drag to, and coreaudiod has to be
# restarted afterwards or the driver does not appear until the next reboot. Both need an
# installer that can run as root and run a script.
#
# LICENSING. The driver is a modified build of BlackHole (GPL-3.0), so this package is a
# distribution of a derivative work. Before anything built here is downloadable, the
# GPL-3.0 obligations must be met — publish the corresponding source, keep the
# LICENSE file inside the driver bundle, and state prominently that this is a modified build
# not supported by Existential Audio. This script checks the LICENSE file is present and
# refuses to build without it, but it cannot check that you published anything.
set -euo pipefail

cd "$(dirname "$0")"

readonly APP="PlugInput.app"
readonly DRIVER_SRC=".build/driver/PlugInput.driver"
readonly OUT=".build/pkg"
readonly PKG_ID="com.pluginput.installer"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
readonly VERSION BUILD

NOTARIZE=false
case "${1:-}" in
    --notarize) NOTARIZE=true ;;
    "")         ;;
    *)          echo "usage: $0 [--notarize]" >&2; exit 2 ;;
esac
readonly NOTARIZE

# --- inputs ---------------------------------------------------------------------------------

echo "==> Building components ($VERSION build $BUILD)"
./make-app.sh release > /dev/null
./make-driver.sh build > /dev/null

[[ -d "$APP" ]]        || { echo "missing $APP" >&2; exit 1; }
[[ -d "$DRIVER_SRC" ]] || { echo "missing $DRIVER_SRC" >&2; exit 1; }

# GPL-3.0: the license text travels inside the bundle we ship. Stripping it is the one
# packaging mistake that cannot be corrected by a later build, because by then it is on other
# people's machines.
if [[ ! -f "$DRIVER_SRC/Contents/Resources/LICENSE" ]]; then
    echo "!!! $DRIVER_SRC is missing Contents/Resources/LICENSE." >&2
    echo "    BlackHole is GPL-3.0 and the license must ship with the binary. Refusing." >&2
    exit 1
fi

# The hardened runtime is required for notarization, and it is enabled in make-app.sh for every
# build so that what gets shipped is what was tested. Verify rather than trust: an unhardened
# bundle is accepted by every local check and rejected only by Apple, at the end.
# Captured into a variable rather than piped straight into `grep -q`. Under `set -o pipefail`
# that pipeline reports failure even when the pattern matches: grep exits at the first hit,
# codesign dies of SIGPIPE, and pipefail surfaces the signal as the pipeline's status. The
# check then fails on a perfectly good bundle.
APP_SIGNATURE="$(codesign -d --verbose=2 "$APP" 2>&1 || true)"
if ! grep -q "flags=.*runtime" <<< "$APP_SIGNATURE"; then
    echo "!!! $APP is not signed with the hardened runtime (--options runtime)." >&2
    echo "    Notarization would reject it. Refusing." >&2
    exit 1
fi

# The driver needs it too. Every publicly distributed HAL driver on this machine carries the
# hardened runtime — stock BlackHole and Zoom's both do, both notarized under a Developer ID.
DRIVER_SIGNATURE="$(codesign -d --verbose=2 "$DRIVER_SRC" 2>&1 || true)"
if ! grep -q "flags=.*runtime" <<< "$DRIVER_SIGNATURE"; then
    echo "!!! $DRIVER_SRC is not signed with the hardened runtime." >&2
    echo "    Notarization would reject it. Refusing." >&2
    exit 1
fi

# Both nested bundles must be signed by the SAME authority, and for a notarized build that
# authority has to be a Developer ID. Notarization validates every nested Mach-O, so a driver
# still carrying the local self-signed leaf while the app carries a Developer ID passes every
# check on this machine and is rejected by Apple minutes later — the slowest possible way to
# find out. Checking the authority here, rather than only the hardened-runtime flag, is what
# makes that failure local and immediate.
APP_AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$APP_SIGNATURE" | head -1)"
DRIVER_AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$DRIVER_SIGNATURE" | head -1)"

echo "==> app signed by:    ${APP_AUTHORITY:-<ad-hoc / unsigned>}"
echo "==> driver signed by: ${DRIVER_AUTHORITY:-<ad-hoc / unsigned>}"

if [[ "$APP_AUTHORITY" != "$DRIVER_AUTHORITY" ]]; then
    echo "!!! The app and driver are signed by different authorities." >&2
    echo "    Notarization validates every nested bundle and would reject the package." >&2
    echo "    Set PLUGINPUT_SIGN_IDENTITY so make-app.sh and make-driver.sh agree." >&2
    exit 1
fi

if [[ "$NOTARIZE" == true && "$APP_AUTHORITY" != "Developer ID Application:"* ]]; then
    echo "!!! --notarize needs a 'Developer ID Application' identity, but the bundles are" >&2
    echo "    signed by '${APP_AUTHORITY:-<ad-hoc / unsigned>}'. Apple would reject this." >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/root-app/Applications" "$OUT/root-driver/Library/Audio/Plug-Ins/HAL" "$OUT/scripts"
cp -R "$APP" "$OUT/root-app/Applications/"
cp -R "$DRIVER_SRC" "$OUT/root-driver/Library/Audio/Plug-Ins/HAL/"

# Ship the uninstaller inside the app bundle.
#
# README tells people to run ./uninstall.sh, which somebody who installed a .pkg does not have
# — the same "instructions written for the one machine this was built on" bug already fixed for
# the driver-missing message. Inside Contents/Resources it travels with the app and survives
# being dragged around, and the app can point at its own copy by absolute path.
cp uninstall.sh "$OUT/root-app/Applications/PlugInput.app/Contents/Resources/uninstall.sh"
chmod +x "$OUT/root-app/Applications/PlugInput.app/Contents/Resources/uninstall.sh"

# --- postinstall ----------------------------------------------------------------------------

# Restarting coreaudiod is how a HAL plug-in gets picked up; there is no lighter-weight signal
# and no API to ask for one. `launchctl kickstart -k` rather than `killall -9`, because a clean
# restart is markedly less likely to make macOS re-elect a default device — and the device it
# elects is the loopback that was just installed, which leaves every app following the system
# default listening to silence. `killall -9` is kept as a fallback for anything that refuses.
cat > "$OUT/scripts/postinstall" <<'POST'
#!/bin/bash
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null \
    || killall -9 coreaudiod 2>/dev/null \
    || true
exit 0
POST
chmod +x "$OUT/scripts/postinstall"

# Quit a running copy before the payload lands on top of it.
#
# Overwriting the bundle of a running app leaves that process running against files that no
# longer exist, and for this app it also means the old copy never reaches `willTerminate` —
# so its aggregate device is orphaned (gotcha #7) and then blocks the *new* copy's first start
# (gotcha #20). `osascript` quits it properly rather than killing it, which is the whole point.
cat > "$OUT/scripts/preinstall" <<'PRE'
#!/bin/bash
if pgrep -x PlugInput > /dev/null 2>&1; then
    osascript -e 'quit app "PlugInput"' 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -x PlugInput > /dev/null 2>&1 || break
        sleep 1
    done
    pkill -9 -x PlugInput 2>/dev/null || true
fi
exit 0
PRE
chmod +x "$OUT/scripts/preinstall"

# --- component packages ---------------------------------------------------------------------

echo "==> pkgbuild"

# Bundle relocation has to be switched off explicitly, and it is not optional.
#
# By default macOS Installer looks for an existing bundle with the same CFBundleIdentifier
# anywhere on the disk and installs *there* instead of at the path in the payload. On a machine
# that has ever had a copy of PlugInput — a developer checkout, an old build in ~/Downloads —
# the app silently lands on top of that copy and never appears in /Applications, while the
# receipt still claims it did. Observed exactly that:
#
#   PackageKit: Applications/PlugInput.app relocated to Users/.../Desktop/Apps/PlugInput.app
#
# `pkgbuild --analyze` writes a component plist describing each bundle it found; setting
# BundleIsRelocatable to false in it pins the install to the payload path.
pkgbuild --analyze --root "$OUT/root-app" "$OUT/app-components.plist" > /dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$OUT/app-components.plist"

# The driver needs the same treatment. It was left out because a HAL driver has nowhere else to
# usefully live — but "unlikely" is not "cannot", and a driver installed anywhere other than
# /Library/Audio/Plug-Ins/HAL simply never loads, silently, which is this project's least
# favourite kind of failure.
pkgbuild --analyze --root "$OUT/root-driver" "$OUT/driver-components.plist" > /dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$OUT/driver-components.plist"

pkgbuild --quiet \
    --root "$OUT/root-app" \
    --identifier "com.pluginput.app" \
    --version "$VERSION" \
    --install-location / \
    --component-plist "$OUT/app-components.plist" \
    "$OUT/PlugInput-app.pkg"

pkgbuild --quiet \
    --root "$OUT/root-driver" \
    --identifier "com.pluginput.driver" \
    --version "$VERSION" \
    --install-location / \
    --component-plist "$OUT/driver-components.plist" \
    --scripts "$OUT/scripts" \
    "$OUT/PlugInput-driver.pkg"

cat > "$OUT/distribution.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>PlugInput $VERSION</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="app"/>
        <line choice="driver"/>
    </choices-outline>
    <choice id="app" title="PlugInput" visible="false">
        <pkg-ref id="com.pluginput.app"/>
    </choice>
    <choice id="driver" title="PlugInput Audio Driver" visible="false">
        <pkg-ref id="com.pluginput.driver"/>
    </choice>
    <pkg-ref id="com.pluginput.app" version="$VERSION">PlugInput-app.pkg</pkg-ref>
    <pkg-ref id="com.pluginput.driver" version="$VERSION">PlugInput-driver.pkg</pkg-ref>
</installer-gui-script>
DIST

# --- signing --------------------------------------------------------------------------------

# The installer needs a *Developer ID Installer* certificate, which is a different certificate
# from the Developer ID Application one that signs the app and driver. Having only the latter
# is the easy mistake here, so the message says which is missing.
INSTALLER_IDENTITY="${PLUGINPUT_INSTALLER_IDENTITY:-}"
if [[ -z "$INSTALLER_IDENTITY" ]]; then
    INSTALLER_IDENTITY="$(security find-identity -v \
        | sed -n 's/.*"\(Developer ID Installer:.*\)"$/\1/p' | head -1)"
fi

readonly FINAL="PlugInput-$VERSION.pkg"
echo "==> productbuild"
if [[ -n "$INSTALLER_IDENTITY" ]]; then
    echo "    signing with '$INSTALLER_IDENTITY'"
    productbuild \
        --distribution "$OUT/distribution.xml" \
        --package-path "$OUT" \
        --sign "$INSTALLER_IDENTITY" \
        "$FINAL"
else
    echo "    NO 'Developer ID Installer' identity found — building UNSIGNED."
    echo "    An unsigned .pkg installs locally but Gatekeeper will refuse it on any other Mac."
    productbuild \
        --distribution "$OUT/distribution.xml" \
        --package-path "$OUT" \
        "$FINAL"
fi

# --- notarization ---------------------------------------------------------------------------

if $NOTARIZE; then
    if [[ -z "$INSTALLER_IDENTITY" ]]; then
        echo "!!! Refusing to notarize an unsigned package." >&2
        exit 1
    fi
    echo "==> Submitting to Apple (this takes minutes, not seconds)"
    # Credentials come from a stored profile so no secret is ever written into this repo:
    #   xcrun notarytool store-credentials pluginput --apple-id ... --team-id ... --password ...
    xcrun notarytool submit "$FINAL" --keychain-profile "pluginput" --wait

    echo "==> Stapling"
    xcrun stapler staple "$FINAL"
    xcrun stapler validate "$FINAL"
fi

# --- report ---------------------------------------------------------------------------------

echo
echo "Built $FINAL"
echo
echo "Verify before publishing — ideally on a Mac that has never seen this app:"
echo "    spctl -a -vvv -t install \"$FINAL\""
echo "    pkgutil --check-signature \"$FINAL\""
echo
echo "Then install it and MEASURE, because a package that installs cleanly and carries silence"
echo "is this project's characteristic failure:"
echo "    cd Spike && ./.build/debug/PlugInputSpike listen 4 PlugInput"
