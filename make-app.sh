#!/bin/bash
# Assembles PlugInput.app from the SwiftPM build.
#
# SwiftPM cannot emit a .app bundle, and this app needs one for two reasons that are not
# optional: a menu bar app must be LSUIElement, and microphone permission is only ever
# granted to a bundle with an Info.plist carrying NSMicrophoneUsageDescription. Running the
# bare executable gets you a dock icon and a silent input.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="PlugInput.app"
BUNDLE_ID="com.pluginput.app"

# One source of truth for the version, shared with make-pkg.sh. The marketing version lives in
# ./VERSION; the build number is the git commit count, which rises monotonically and needs no
# bookkeeping. Both are required to be sane by the installer: macOS will refuse to "upgrade" to
# a package whose CFBundleVersion is not greater than the installed one.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "==> Version $VERSION (build $BUILD)"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/PlugInput"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PlugInput"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PlugInput</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>PlugInput</string>
    <key>CFBundleDisplayName</key><string>PlugInput</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no dock icon, no main window. -->
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>PlugInput processes your microphone through audio plugins in real time.</string>
</dict>
</plist>
PLIST

ENTITLEMENTS="$(mktemp -t pluginput-entitlements)"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <!--
      Mandatory to load third-party Audio Units. Plugin bundles are signed by their vendors,
      not by us, so library validation would reject every one of them.
      Note there is deliberately NO app-sandbox entitlement: a sandboxed app cannot read
      /Library/Audio/Plug-Ins/Components at all.
    -->
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists, and fall back to ad-hoc when it does not.
#
# This is not cosmetic. TCC records a *code requirement* against the microphone grant, and
# ad-hoc signing ("-") derives that requirement from the binary's cdhash — which changes on
# every single build. macOS then logs "Failed to match existing code requirement for subject
# com.pluginput.app and service kTCCServiceMicrophone" and re-prompts, and until the dialog is
# answered the app records exact digital silence while every layer reports success. A stable
# self-signed leaf keeps one identity across rebuilds, so the grant survives them.
#
# Recreate the identity on a new machine with (any CN works, keep it matching SIGN_IDENTITY):
#   openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
#     -subj "/CN=PlugInput Local Signing" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -out id.p12 -inkey k.pem -in c.pem -passout pass:PASSWORD \
#     -name "PlugInput Local Signing" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
#   security import id.p12 -k ~/Library/Keychains/login.keychain-db -P PASSWORD -T /usr/bin/codesign
#
# Identity selection, in priority order:
#   1. $PLUGINPUT_SIGN_IDENTITY, so a release build can name an identity explicitly
#   2. a "Developer ID Application" identity, if the machine has one — the distribution
#      identity, and using it locally means the build that gets notarized is the build
#      that was actually tested
#   3. the self-signed local leaf described above
#   4. ad-hoc, which re-prompts for the microphone on every rebuild
SIGN_AS="${PLUGINPUT_SIGN_IDENTITY:-}"

# Read the identity list once into a variable. Piping it straight into `grep -q` is unsafe
# under `set -o pipefail`: grep exits on the first match, `security` dies of SIGPIPE, and the
# pipeline reports failure despite the match — which here would silently drop the build to
# ad-hoc signing, and ad-hoc signing means a microphone re-prompt and silent capture until it
# is answered.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"

if [[ -z "$SIGN_AS" ]]; then
    SIGN_AS="$(sed -n 's/.*"\(Developer ID Application:.*\)"$/\1/p' <<< "$IDENTITIES" | head -1)"
fi
if [[ -z "$SIGN_AS" ]] && grep -q "PlugInput Local Signing" <<< "$IDENTITIES"; then
    SIGN_AS="PlugInput Local Signing"
fi
if [[ -z "$SIGN_AS" ]]; then
    echo "==> Signing (ad-hoc — expect a microphone prompt after every rebuild)"
    SIGN_AS="-"
else
    echo "==> Signing ($SIGN_AS)"
fi

# --options runtime is ALWAYS on, not only for release builds.
#
# Notarization rejects a bundle without the hardened runtime, but the reason to enable it here
# rather than in a separate release path is that the hardened runtime is enforced by the
# *kernel* regardless of which certificate signed the bundle. A locally-signed build with it on
# therefore exercises exactly the restrictions a notarized build will face, which is the only
# way to find out before shipping that it does not stop third-party Audio Units from loading.
# (It does not, because disable-library-validation is in the entitlements above — but this
# project's whole history is layers reporting success while producing silence, so it is
# measured, not assumed. See RELEASE.md.)
codesign --force --sign "$SIGN_AS" --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP" 2>&1 | sed 's/^/    /'
rm -f "$ENTITLEMENTS"

echo
echo "Built $APP"
echo "  open $APP          # launch (look for the waveform icon in the menu bar)"
echo "  killall PlugInput  # stop"
