#!/bin/zsh
# Builds FoundationChat.app from main.swift. No Xcode project needed.
set -e
cd "$(dirname "$0")"

swiftc -O main.swift -o FoundationChat

APP=FoundationChat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv FoundationChat "$APP/Contents/MacOS/FoundationChat"

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
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP — launch with: open $APP"
