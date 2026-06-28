#!/usr/bin/env bash
# Build TailRDP SwiftUI executable and assemble a double-clickable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="TailRDP"
BUNDLE_ID="com.aegis.rdp"
VERSION="1.0.0"
CONFIG="${1:-release}"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN"; exit 1; }

BUNDLE="$APP.app"
echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
    ICON_PLIST='    <key>CFBundleIconFile</key>       <string>AppIcon</string>'
else
    ICON_PLIST=""
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP</string>
    <key>CFBundleDisplayName</key>     <string>$APP</string>
    <key>CFBundleExecutable</key>      <string>$APP</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
$ICON_PLIST
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || echo "(codesign skipped)"

# Install so Spotlight/Launchpad can find it; keep /Applications current on rebuild.
INSTALL_DIR="/Applications"
if ! touch "$INSTALL_DIR/.aegisrdp_wtest" 2>/dev/null; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
else
    rm -f "$INSTALL_DIR/.aegisrdp_wtest"
fi
echo "==> installing to $INSTALL_DIR"
rm -rf "$INSTALL_DIR/$BUNDLE"
cp -R "$BUNDLE" "$INSTALL_DIR/$BUNDLE"

echo "==> done: $INSTALL_DIR/$BUNDLE"
