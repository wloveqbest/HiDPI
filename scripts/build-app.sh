#!/bin/bash
#
# 构建 HiDPI 菜单栏 App：编译 → 组装 .app → 生成图标 → ad-hoc 签名 → 打包 DMG
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="HiDPI"
BUNDLE_ID="pro.local.hidpi"
VERSION="0.2.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> 编译 release"
swift build -c release

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/HiDPIMenuBar" "$APP/Contents/MacOS/hidpi"
cp "$ROOT/.build/release/hidpi" "$APP/Contents/MacOS/hidpi-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>hidpi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>MIT License — 机制参考 BetterDummy OpenSource Edition (MIT, Istvan T.)</string>
</dict>
</plist>
PLIST

echo "==> 生成图标"
if [ ! -f "$ROOT/.build/AppIcon.icns" ]; then
  ICONSET="$ROOT/.build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/.build/icon-1024.png" >/dev/null
  for size in 16 32 64 128 256 512 1024; do
    sips -z "$size" "$size" "$ROOT/.build/icon-1024.png" \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    if [ "$size" -gt 16 ]; then
      double=$((size * 2))
      cp "$ICONSET/icon_${double}x${double}.png" "$ICONSET/icon_${size}x${size}@2x.png" 2>/dev/null || true
    fi
  done
  # 补齐 @2x 条目
  for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/.build/icon-1024.png" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns"
fi
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP"

echo "==> 校验"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> 打包 DMG"
rm -rf "$DIST/dmg" && mkdir -p "$DIST/dmg"
cp -R "$APP" "$DIST/dmg/"
ln -s /Applications "$DIST/dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DIST/dmg" -ov -format UDZO \
  "$DIST/$APP_NAME-$VERSION.dmg" >/dev/null
rm -rf "$DIST/dmg"

echo
echo "完成:"
echo "  $APP"
echo "  $DIST/$APP_NAME-$VERSION.dmg"
ls -lh "$DIST/$APP_NAME-$VERSION.dmg" | awk '{print "  DMG 大小: "$5}'
