#!/bin/sh
# Builds build/TouchGlass.app with SwiftPM and signs it ad hoc.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
# TOUCHGLASS_VERSION sets CFBundleShortVersionString and CFBundleVersion (default 0.1.0).
set -eu

configuration="${1:-release}"
version="${TOUCHGLASS_VERSION:-0.1.0}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c "$configuration" --product TouchGlass
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

app="build/TouchGlass.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/TouchGlass" "$app/Contents/MacOS/TouchGlass"

# Helper executables ship inside the bundle when the package defines them.
for helper in touchglass-pinentry touchglass-scdaemon; do
    if grep -q "name: \"$helper\"" Package.swift; then
        swift build -c "$configuration" --product "$helper"
        cp "$bin_dir/$helper" "$app/Contents/MacOS/$helper"
    fi
done

# The install CLI. The Homebrew cask links it onto PATH; run from here, it works on this bundle.
mkdir -p "$app/Contents/Resources"
cp scripts/touchglass "$app/Contents/Resources/touchglass"
chmod 755 "$app/Contents/Resources/touchglass"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.ambroos.touchglass</string>
    <key>CFBundleName</key>
    <string>TouchGlass</string>
    <key>CFBundleDisplayName</key>
    <string>TouchGlass</string>
    <key>CFBundleExecutable</key>
    <string>TouchGlass</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$app"
echo "Built $root/$app"
