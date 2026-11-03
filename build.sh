#!/bin/zsh
set -e
cd "$(dirname "$0")"

APP=build/OneShutdown.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/"

# BorderBeamKit 编一次产出双 arch 的 .swiftmodule;静态库分别抽 arm64/x86_64 两份
(cd Packages/BorderBeamKit && swift build -c release --arch arm64 && swift build -c release --arch x86_64)

OUT=Packages/BorderBeamKit/.build/out
BB=$OUT/Products/Release
# beam-spec.json + default.metallib(Bundle.module 从这里读;两个 arch 内容一样)
ditto "$BB/BorderBeamKit_BorderBeamKit.bundle" "$APP/Contents/Resources/BorderBeamKit_BorderBeamKit.bundle"

for ARCH in arm64 x86_64; do
  OBJ="$OUT/Intermediates.noindex/BorderBeamKit.build/Release/BorderBeamKit-t.build/Objects-normal/$ARCH"
  ar rcs build/libBB-$ARCH.a "$OBJ"/*.o
  swiftc -O -target $ARCH-apple-macos14 Sources/main.swift \
    -I "$BB" build/libBB-$ARCH.a \
    -o build/OneShutdown-$ARCH
done
lipo -create build/OneShutdown-arm64 build/OneShutdown-x86_64 -output "$APP/Contents/MacOS/OneShutdown"
rm build/OneShutdown-arm64 build/OneShutdown-x86_64 build/libBB-*.a

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>OneShutdown</string>
    <key>CFBundleDisplayName</key>       <string>OneShutdown</string>
    <key>CFBundleIdentifier</key>        <string>com.zephyr.one-shutdown</string>
    <key>CFBundleExecutable</key>        <string>OneShutdown</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key>           <string>5</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
EOF

# 有 Developer ID 证书就用它签名,否则 ad-hoc
SIGN_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  echo "🔑 签名: $SIGN_ID"
else
  codesign --force --deep --sign - "$APP"
  echo "⚠️  未找到 Developer ID,使用 ad-hoc 签名"
fi

# 可选公证:RELEASE_ENV=<含 APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID 的文件> ./build.sh
if [[ -n "$RELEASE_ENV" ]]; then
  ( set +x; set -a; . "$RELEASE_ENV"; set +a
    ditto -c -k --keepParent "$APP" build/notarize.zip
    xcrun notarytool submit build/notarize.zip --wait \
      --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" )
  rm build/notarize.zip
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP"
  ditto -c -k --keepParent "$APP" build/OneShutdown.zip
  echo "📦 build/OneShutdown.zip(已公证)"
fi

echo "✅ $APP"