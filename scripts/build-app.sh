#!/bin/sh
# Builds build/TouchGlass.app with SwiftPM and signs it ad hoc.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
#        scripts/build-app.sh --prebuilt DIR    (bundles the executables in DIR; builds nothing)
# TOUCHGLASS_VERSION sets CFBundleShortVersionString and CFBundleVersion (default 0.1.0).
# --prebuilt is for builds that run swift build themselves, such as the Homebrew formula.
set -eu

version="${TOUCHGLASS_VERSION:-0.1.0}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
products="TouchGlass touchglass-pinentry touchglass-scdaemon"

if [ "${1:-}" = --prebuilt ]; then
    [ $# -eq 2 ] || { echo "usage: $0 --prebuilt DIR" >&2; exit 2; }
    bin_dir="$(cd "$2" && pwd)"
else
    configuration="${1:-release}"
    for product in $products; do
        swift build -c "$configuration" --product "$product"
    done
    bin_dir="$(swift build -c "$configuration" --show-bin-path)"
fi

app="build/TouchGlass.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
for product in $products; do
    cp "$bin_dir/$product" "$app/Contents/MacOS/$product"
done

# The install CLI, stamped with the version. Homebrew links it onto PATH; run from here, it works on
# this bundle.
mkdir -p "$app/Contents/Resources"
sed "s/^cli_version=dev\$/cli_version=$version/" scripts/touchglass > "$app/Contents/Resources/touchglass"
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
