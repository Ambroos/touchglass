#!/bin/sh
# Captures the panel states for the README as transparent PNGs in docs/images/.
#
# For each state and colour scheme, it runs `TouchGlass --hold <state>` twice, once over a white
# and once over a black full-screen backdrop. The app captures the panel window's region itself,
# so no Screen Recording permission is needed, and touchglass-matte recovers a transparent PNG
# from the two captures. Each run covers the panel's screen for about 2 seconds, so leave the Mac
# alone while it runs. The screen must be unlocked and awake.
#
# Usage: scripts/screenshots.sh [options]
#   --states a,b         Capture only these states (default: all; see TouchGlass --help).
#   --schemes a,b        light, dark, or both (default: light,dark).
#   --smoked             Also capture the smoked appearance, which looks the same in both schemes.
#   --plain              Also write the white- and black-backdrop captures, cropped like the matte.
#   --grey               Also write the matte over mid-grey, to check its edges for fringes.
#   --padding <pixels>   Margin around the panel's shadow in the output (default 24).
#   --out <dir>          Output directory (default docs/images).
#   --skip-build         Use the existing build/TouchGlass.app and touchglass-matte.
#   --dry-run            Print what would run, without building or showing anything.
#
# Output names: <state>.png (light), <state>-dark.png, <state>-smoked.png; with --plain, the same
# names with -white, -black or -grey before .png.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

all_states="pin-entry pin-retry touch ssh success wrong-pin timeout"
states="$all_states"
schemes="light dark"
smoked=0
plain=0
grey=0
padding=24
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
        --smoked) smoked=1; shift ;;
        --plain) plain=1; shift ;;
        --grey) grey=1; shift ;;
        --padding) [ $# -ge 2 ] || die "--padding needs a number"; padding="$2"; shift 2 ;;
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
case "$padding" in
    ''|*[!0-9]*) die "--padding needs a whole number of pixels" ;;
esac

app="build/TouchGlass.app/Contents/MacOS/TouchGlass"
bin_dir="$(swift build -c release --show-bin-path 2>/dev/null || echo .build/release)"
matte="$bin_dir/touchglass-matte"

run() {
    if [ "$dry" = 1 ]; then
        echo "+ $*"
    else
        "$@"
    fi
}

# The looks to capture: "<scheme> <appearance> <name suffix>".
looks=""
for scheme in $schemes; do
    case "$scheme" in
        light) looks="$looks light:readable:" ;;
        dark) looks="$looks dark:readable:-dark" ;;
    esac
done
[ "$smoked" = 1 ] && looks="$looks dark:smoked:-smoked"

if [ "$build" = 1 ]; then
    run scripts/build-app.sh release
    run swift build -c release --product touchglass-matte
fi
if [ "$dry" = 0 ]; then
    [ -x "$app" ] || die "$app is missing; run without --skip-build"
    [ -x "$matte" ] || die "$matte is missing; run without --skip-build"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/touchglass-shots.XXXXXX")"
pid=""
cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

run mkdir -p "$out"

# capture <state> <scheme> <appearance> <backdrop> <png>
# The app captures its own windows, which needs no Screen Recording permission.
capture() {
    log="$work/hold.log"
    if [ "$dry" = 1 ]; then
        echo "+ $app --hold $1 --color-scheme $2 --appearance $3 --backdrop $4 --capture $5 &   # wait for its captured line, then stop it"
        return
    fi
    : > "$log"
    "$app" --hold "$1" --color-scheme "$2" --appearance "$3" --backdrop "$4" --capture "$5" > "$log" 2>&1 &
    pid=$!

    # The runner prints its ready line about 2 seconds after launch, then captures.
    tries=0
    until grep -q '^captured ' "$log"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            pid=""
            cat "$log" >&2
            die "TouchGlass --hold $1 exited before it captured the panel"
        fi
        tries=$((tries + 1))
        [ "$tries" -le 150 ] || die "TouchGlass --hold $1 captured nothing within 15 seconds"
        sleep 0.1
    done
    grep -q 'key=true' "$log" || echo "screenshots: warning: the panel was not key for $1 over $4, so the glass may lack its key look" >&2

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
    [ -s "$5" ] || die "the capture $5 is empty"
}

for look in $looks; do
    scheme="${look%%:*}"
    rest="${look#*:}"
    appearance="${rest%%:*}"
    suffix="${rest#*:}"
    for state in $states; do
        name="$state$suffix"
        echo "$name: $appearance glass, $scheme scheme"
        capture "$state" "$scheme" "$appearance" white "$work/$name-white.png"
        capture "$state" "$scheme" "$appearance" black "$work/$name-black.png"
        set -- --white "$work/$name-white.png" --black "$work/$name-black.png" --out "$out/$name.png" --padding "$padding"
        if [ "$plain" = 1 ]; then
            set -- "$@" --white-out "$out/$name-white.png" --black-out "$out/$name-black.png"
        fi
        [ "$grey" = 1 ] && set -- "$@" --composite-out "$out/$name-grey.png"
        run "$matte" "$@"
    done
done
