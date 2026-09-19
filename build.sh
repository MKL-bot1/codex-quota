#!/bin/zsh
set -euo pipefail
umask 077
cd "$(dirname "$0")"
SOURCE_ROOT="$PWD"
BUILD_TEMP="$(mktemp -d "${TMPDIR:-/tmp/}codexquota-build.XXXXXX")"
trap 'rm -rf "$BUILD_TEMP"' EXIT
APP="$SOURCE_ROOT/dist/Codex Quota.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns assets/BrandMark.png assets/StatusIcon.png assets/StatusIcon@2x.png "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
for ARCH in arm64 x86_64; do
    xcrun swiftc Sources/main.swift -O -target "$ARCH-apple-macos14.0" \
        -file-prefix-map "$SOURCE_ROOT=." -debug-prefix-map "$SOURCE_ROOT=." \
        -module-cache-path "$BUILD_TEMP/module-cache" \
        -o "$BUILD_TEMP/CodexQuota-$ARCH" \
        -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Security
done
lipo -create "$BUILD_TEMP/CodexQuota-arm64" "$BUILD_TEMP/CodexQuota-x86_64" -output "$APP/Contents/MacOS/CodexQuota"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexQuota</string>
<key>CFBundleIdentifier</key><string>io.github.codexquota.app</string>
<key>CFBundleName</key><string>Codex Quota</string>
<key>CFBundleDisplayName</key><string>Codex Quota</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
find "$APP" -type d -exec chmod 755 {} +
find "$APP" -type f -exec chmod 644 {} +
chmod 755 "$APP/Contents/MacOS/CodexQuota"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/CodexQuota" --self-test
printf 'Built: %s\n' "$APP"
