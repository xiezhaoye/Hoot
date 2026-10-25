#!/bin/bash
# Builds ShotPad.app (release) and signs it. A stable signing identity keeps the
# Screen Recording permission across rebuilds; ad-hoc signing would reset it every time.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SHOTPAD_IDENTITY:-Apple Development: xiezhaoye@gmail.com (N5Y4XA8R9F)}"
swift build -c release
APP=ShotPad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/ShotPad "$APP/Contents/MacOS/ShotPad"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.xiezhaoye.shotpad</string>
<key>CFBundleName</key><string>ShotPad</string>
<key>CFBundleDisplayName</key><string>ShotPad</string>
<key>CFBundleExecutable</key><string>ShotPad</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>ShotPad 需要录制屏幕内容来截图。</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" | head -2
echo "built $(pwd)/$APP"
