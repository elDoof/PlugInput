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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
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
# For distribution, swap in a Developer ID identity and add --options runtime.
SIGN_IDENTITY="PlugInput Local Signing"

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "==> Signing ($SIGN_IDENTITY)"
    SIGN_AS="$SIGN_IDENTITY"
else
    echo "==> Signing (ad-hoc — expect a microphone prompt after every rebuild)"
    SIGN_AS="-"
fi

codesign --force --sign "$SIGN_AS" --entitlements "$ENTITLEMENTS" "$APP" 2>&1 | sed 's/^/    /'
rm -f "$ENTITLEMENTS"

echo
echo "Built $APP"
echo "  open $APP          # launch (look for the waveform icon in the menu bar)"
echo "  killall PlugInput  # stop"
