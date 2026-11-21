#!/bin/bash
set -euo pipefail
rm -rf build && mkdir -p build
APP=build/StormPad.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
  swiftc -O -sdk "$SDK" -target "$arch-apple-macos12.0" Sources/*.swift -o "build/StormPad-$arch"
done
lipo -create build/StormPad-arm64 build/StormPad-x86_64 -output "$APP/Contents/MacOS/StormPad"
cp Info.plist "$APP/Contents/Info.plist"
# icon
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2)); sips -z $d $d icon1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
(cd build && ditto -c -k --keepParent StormPad.app StormPad.zip)
echo "Built build/StormPad.zip"
