#!/bin/bash
# Renders Resources/AppIcon.icns from Tools/render-icon.swift.
#
# The .icns is committed, so this only needs running when the artwork changes — make-app.sh
# copies the committed file rather than regenerating it, which keeps a release build from
# depending on a working swift toolchain for its icon.
set -euo pipefail

cd "$(dirname "$0")"

ICONSET="$(mktemp -d -t pluginput-iconset)/AppIcon.iconset"
OUTPUT="Resources/AppIcon.icns"

echo "==> Rendering icon representations"
mkdir -p "$ICONSET" Resources
swift Tools/render-icon.swift "$ICONSET"

echo "==> Packing $OUTPUT"
iconutil --convert icns --output "$OUTPUT" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"

# Verified, not assumed: iconutil exits 0 having written an icns that is missing
# representations, and the first symptom is a blurry icon at exactly one size in the Dock.
# Unpacking it back to an iconset and counting is the only check that sees inside the file.
EXPECTED=10
ROUNDTRIP="$(mktemp -d -t pluginput-icns-check)"
iconutil --convert iconset --output "$ROUNDTRIP/AppIcon.iconset" "$OUTPUT"
ACTUAL="$(find "$ROUNDTRIP/AppIcon.iconset" -name '*.png' | wc -l | tr -d '[:space:]')"
rm -rf "$ROUNDTRIP"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "!!! $OUTPUT carries $ACTUAL representations, expected $EXPECTED." >&2
    exit 1
fi

echo "==> Wrote $OUTPUT ($(du -h "$OUTPUT" | cut -f1), $ACTUAL representations)"
