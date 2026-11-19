#!/bin/sh
# Captures the panel states for the README as PNGs in docs/images/.
#
# For each state and colour scheme, it runs `touchglass-screenshots <state>` once, over a full-screen
# backdrop in the colour of GitHub's page: light over #ffffff, dark over #0d1117. The glass takes its
# tint from what is behind it, so each image only looks right on that page colour.
# touchglass-screenshots is a developer tool that shows the app's panel; it is not part of
# TouchGlass.app. It captures the panel window's region itself, shadow included, at the screen's pixel
# scale, so no Screen Recording permission is needed. Each run covers the panel's screen for about 2
# seconds, so leave the Mac alone while it runs. The screen must be unlocked and awake.
#
# Usage: scripts/screenshots.sh [options]
#   --states a,b         Capture only these states (default: all; see touchglass-screenshots --help).
#   --schemes a,b        light, dark, or both (default: light,dark).
#   --out <dir>          Output directory (default docs/images).
#   --skip-build         Use the existing build/TouchGlassScreenshots.app.
#   --dry-run            Print what would run, without building or showing anything.
#
# Output names: <state>.png (light) and <state>-dark.png.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

all_states="pin-entry pin-retry touch ssh success wrong-pin timeout"
states="$all_states"
schemes="light dark"
out="docs/images"
build=1
dry=0

die() {
    echo "screenshots: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --states) [ $# -ge 2 ] || die "--states needs a list"; states="$(echo "$2" | tr ',' ' ')"; shift 2 ;;
        --schemes) [ $# -ge 2 ] || die "--schemes needs a list"; schemes="$(echo "$2" | tr ',' ' ')"; shift 2 ;;
        --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; shift 2 ;;
        --skip-build) build=0; shift ;;
        --dry-run) dry=1; shift ;;
        -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
done

for state in $states; do
    case " $all_states " in
        *" $state "*) ;;
        *) die "unknown state $state; states: $all_states" ;;
    esac
done
for scheme in $schemes; do
    case "$scheme" in
        light|dark) ;;
        *) die "unknown scheme $scheme; schemes: light, dark" ;;
    esac
done

bundle="build/TouchGlassScreenshots.app"
app="$bundle/Contents/MacOS/touchglass-screenshots"
bin_dir="$(swift build -c release --show-bin-path 2>/dev/null || echo .build/release)"

run() {
    if [ "$dry" = 1 ]; then
        echo "+ $*"
    else
        "$@"
    fi
}

# Wraps touchglass-screenshots in a minimal bundle, so it runs as an app with an Info.plist, as
# TouchGlass does. The bundle has its own identifier and name, so LaunchServices never takes it
# for TouchGlass.
make_bundle() {
    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS"
    cp "$bin_dir/touchglass-screenshots" "$app"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.ambroos.touchglass.screenshots</string>
    <key>CFBundleName</key>
    <string>TouchGlassScreenshots</string>
    <key>CFBundleExecutable</key>
    <string>touchglass-screenshots</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
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
    codesign --force --sign - --timestamp=none "$bundle"
}

if [ "$build" = 1 ]; then
    run swift build -c release --product touchglass-screenshots
    run make_bundle
fi
if [ "$dry" = 0 ]; then
    [ -x "$app" ] || die "$app is missing; run without --skip-build"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/touchglass-shots.XXXXXX")"
pid=""
cleanup() {
    # Stops only the process this script started, by its PID.
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

run mkdir -p "$out"

# capture <state> <scheme> <backdrop> <png>
capture() {
    log="$work/hold.log"
    if [ "$dry" = 1 ]; then
        echo "+ $app $1 --color-scheme $2 --backdrop $3 --capture $4 &   # wait for its captured line, then stop it"
        return
    fi
    : > "$log"
    "$app" "$1" --color-scheme "$2" --backdrop "$3" --capture "$4" > "$log" 2>&1 &
    pid=$!

    # The tool prints its ready line about 2 seconds after launch, then captures. It checks that the
    # screen is unlocked and awake first, and exits with a message if it isn't.
    tries=0
    until grep -q '^captured ' "$log"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            pid=""
            cat "$log" >&2
            die "touchglass-screenshots $1 exited before it captured the panel"
        fi
        tries=$((tries + 1))
        [ "$tries" -le 150 ] || die "touchglass-screenshots $1 captured nothing within 15 seconds"
        sleep 0.1
    done
    grep -q 'key=true' "$log" || echo "screenshots: warning: the panel was not key for $1, so the glass may lack its key look" >&2

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
    [ -s "$4" ] || die "the capture $4 is empty"
}

for scheme in $schemes; do
    case "$scheme" in
        light) backdrop="#ffffff"; suffix="" ;;
        dark) backdrop="#0d1117"; suffix="-dark" ;;
    esac
    for state in $states; do
        echo "$state$suffix: $scheme scheme over $backdrop"
        capture "$state" "$scheme" "$backdrop" "$out/$state$suffix.png"
    done
done
