#!/bin/zsh
# Builds FoundationChat.app (GUI) and isaac (CLI). No Xcode project needed.
set -e
cd "$(dirname "$0")"

TARGET=arm64-apple-macos27.0

APP=FoundationChat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target $TARGET Core.swift main.swift -o "$APP/Contents/MacOS/FoundationChat"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FoundationChat</string>
    <key>CFBundleIdentifier</key>
    <string>com.ivankaliaev.foundationchat</string>
    <key>CFBundleName</key>
    <string>FoundationChat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

swiftc -O -target $TARGET -parse-as-library Core.swift cli.swift -o isaac
codesign --force --sign - isaac

echo "Built $APP — launch with: open $APP"
echo "Built isaac — try: ./isaac --help"
