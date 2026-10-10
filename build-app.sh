#!/bin/zsh
# Builds a release TabManager.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --product TabManager

# Render the icon only when its drawing script changes.
icns=build/AppIcon.icns
if [[ ! -f $icns || Icon/make-icon.swift -nt $icns ]]; then
    iconset=build/AppIcon.iconset
    rm -rf "$iconset" && mkdir -p "$iconset"
    swift Icon/make-icon.swift build/icon-1024.png
    for px in 16 32 128 256 512; do
        sips -z $px $px build/icon-1024.png --out "$iconset/icon_${px}x${px}.png" >/dev/null
        sips -z $((px * 2)) $((px * 2)) build/icon-1024.png --out "$iconset/icon_${px}x${px}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$icns"
fi

app=build/TabManager.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/TabManager "$app/Contents/MacOS/TabManager"
cp "$icns" "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tab Manager</string>
    <key>CFBundleDisplayName</key><string>Tab Manager</string>
    <key>CFBundleIdentifier</key><string>local.tabmanager</string>
    <key>CFBundleExecutable</key><string>TabManager</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/TabManager.app
    cp -R "$app" /Applications/
    rm -rf ~/Applications/TabManager.app # earlier versions installed here
    echo "Installed to /Applications/TabManager.app"
fi
