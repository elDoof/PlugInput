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

# Release builds are universal; debug builds are native, because a second slice doubles the
# compile for an iteration nobody ships.
#
# This is not optional for a public release. The driver has always been universal (xcodebuild
# defaults to it), the installer's distribution.xml declares hostArchitectures="arm64,x86_64",
# and the README promises "Apple silicon or Intel" — but `swift build` defaults to the host
# architecture alone, so every build so far was arm64-only. An Intel Mac would have been
# allowed to install a package whose app could not run natively on it.
ARCH_ARGS=()
if [[ "$CONFIG" == "release" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

# `"${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}"` rather than the plain expansion: macOS ships bash 3.2,
# where an empty array under `set -u` is an *unbound variable*, not an empty list. So
# `./make-app.sh debug` — the only path that leaves this array empty — exited before it built
# anything, while release builds worked and hid it.
echo "==> Building ($CONFIG${ARCH_ARGS:+, universal})"
swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}"
BINARY="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" --show-bin-path)/PlugInput"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PlugInput"

# The uninstaller ships inside the bundle, and it is copied in HERE — before signing — on
# purpose. It used to be added by make-pkg.sh, which runs after this script has already signed
# the app, and dropping a file into Contents/Resources invalidates the bundle seal: every local
# check still passed (`codesign --strict` verifies the bundle on disk, which was fine) and Apple
# rejected the upload minutes later with "The signature of the binary is invalid". Anything
# added to the bundle has to be added before the `codesign` at the end of this file.
cp "$(dirname "$0")/uninstall.sh" "$APP/Contents/Resources/uninstall.sh"
chmod +x "$APP/Contents/Resources/uninstall.sh"

# The icon, copied for the same reason and under the same rule: before the codesign below.
# It is a committed artifact rather than something rendered here, so assembling the app needs
# no toolchain beyond the compiler — but a missing file must stop the build rather than ship a
# bundle that silently falls back to the generic application icon.
ICON="$(dirname "$0")/Resources/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
    echo "!!! $ICON is missing. Run ./make-icon.sh to render it." >&2
    exit 1
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# Verified, not assumed — the recurring lesson here. A release build that quietly produced one
# slice would ship an installer promising Intel support it cannot honour.
if [[ "$CONFIG" == "release" ]]; then
    SLICES="$(lipo -archs "$APP/Contents/MacOS/PlugInput" 2>/dev/null || echo "")"
    echo "==> Architectures: ${SLICES:-unknown}"
    for want in arm64 x86_64; do
        if [[ "$SLICES" != *"$want"* ]]; then
            echo "!!! release build is missing the $want slice (got: ${SLICES:-none})." >&2
            exit 1
        fi
    done
fi

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
    <!--
      CFBundleIconFile is the key Finder, the installer and the About panel read. The name is
      the file's, without its extension. LSUIElement means the app has no dock tile, so the
      icon is not cosmetic in the usual place it would be: it is what the user sees in the
      .pkg, in Applications, and in the Privacy & Security microphone list.
    -->
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
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
    <!--
      Equally mandatory, and for a different reason than the line above (see gotcha #23).
      Copy-protected plugins - UAD, Waves, Slate, anything wrapped in PACE/iLok - decrypt
      their own code into memory at load time and execute it. Under the hardened runtime the
      kernel hashes executable pages on fault-in, finds the rewritten page does not match the
      signature, and SIGKILLs the *host* with CODESIGNING "Invalid Page". Not a catchable
      error, not a plugin-level failure: the whole app dies mid-dlopen.
      disable-library-validation does not cover this - it governs who signed the library, not
      whether its pages may be rewritten after mapping.
      Empirical check, not a guess: Ableton Live 12, which hosts these plugins on this machine,
      ships exactly these two cs.* entitlements and no others.
    -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
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
# measured, not assumed.)
# --timestamp is required for notarization: Apple rejects a signature without a secure
# timestamp. It cannot be used with an ad-hoc signature, which has nowhere to put one.
TIMESTAMP_ARGS=(--timestamp)
[[ "$SIGN_AS" == "-" ]] && TIMESTAMP_ARGS=()
codesign --force --sign "$SIGN_AS" --options runtime "${TIMESTAMP_ARGS[@]}" \
    --entitlements "$ENTITLEMENTS" "$APP" 2>&1 | sed 's/^/    /'
rm -f "$ENTITLEMENTS"

echo
echo "Built $APP"
echo "  open $APP          # launch (look for the waveform icon in the menu bar)"
echo "  killall PlugInput  # stop"
