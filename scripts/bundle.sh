#!/bin/bash
# Builds Hoot.app (release) and signs it. A stable signing identity keeps the
# Screen Recording permission across rebuilds; ad-hoc signing would reset it every time.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SHOTPAD_IDENTITY:-Apple Development: xiezhaoye@gmail.com (N5Y4XA8R9F)}"

# 版本号的唯一来源：仓库根目录的 VERSION（第 1 行营销版本 X.Y.Z，第 2 行 build 号）。
# 不要在这里或 Info.plist 里另写版本号——漏改会让 UpdateManager 认为“已是最新”，
# 自动更新静默失效（见 错题本.md）。
[ -f VERSION ] || { echo "缺少 VERSION 文件" >&2; exit 1; }
MARKETING_VERSION="$(sed -n '1p' VERSION | tr -d '[:space:]')"
BUILD_NUMBER="$(sed -n '2p' VERSION | tr -d '[:space:]')"
[[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION 第 1 行必须是 X.Y.Z：'$MARKETING_VERSION'" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "VERSION 第 2 行必须是整数 build 号：'$BUILD_NUMBER'" >&2; exit 1; }
grep -q "^## ${MARKETING_VERSION}$" CHANGELOG.md \
  || echo "提示：CHANGELOG.md 还没有 '## ${MARKETING_VERSION}' 段落，发版前补上（只增不改）" >&2

swift build -c release
APP=Hoot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/logo.png "$APP/Contents/Resources/logo.png"
cp Resources/brand-lockup.pdf "$APP/Contents/Resources/brand-lockup.pdf"
cp .build/release/ShotPad "$APP/Contents/MacOS/Hoot"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.xiezhaoye.shotpad</string>
<key>CFBundleName</key><string>Hoot</string>
<key>CFBundleDisplayName</key><string>Hoot</string>
<key>CFBundleExecutable</key><string>Hoot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Hoot 需要录制屏幕内容来截图。</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" | head -2
echo "built $(pwd)/$APP  ($MARKETING_VERSION / build $BUILD_NUMBER)"
