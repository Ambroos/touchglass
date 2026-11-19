#!/bin/sh
# Builds, signs, notarizes and zips a TouchGlass release, the direct download on GitHub.
# Usage: scripts/release.sh [--dry-run | --no-notarize] <version>
#
# Signs with TOUCHGLASS_SIGN_IDENTITY, or else with the only "Developer ID Application" identity in the
# keychain, and notarizes with the notarytool keychain profile in TOUCHGLASS_NOTARY_PROFILE (default
# "touchglass"). --dry-run signs ad hoc and skips notarization, to test the pipeline without a
# certificate. --no-notarize signs with the Developer ID identity and skips notarization, to test the
# signature without notarization credentials. Neither zip is for publishing.
#
# Builds a universal app for Apple silicon and Intel Macs. Writes build/release/TouchGlass-<version>.zip
# and prints its SHA-256. Creates no tag or GitHub release; it prints the command for that.
set -eu

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

dry_run=0
notarize=1
version=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1; notarize=0; shift ;;
        --no-notarize) notarize=0; shift ;;
        -h | --help) sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) [ -z "$version" ] || die "one version only"; version="$1"; shift ;;
    esac
done
[ -n "$version" ] || die "usage: scripts/release.sh [--dry-run | --no-notarize] <version>"
# CFBundleVersion takes at most three dot-separated integers.
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version must look like 1.2.3: $version"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
profile="${TOUCHGLASS_NOTARY_PROFILE:-touchglass}"
out="build/release"
app="$out/TouchGlass.app"
zip="$out/TouchGlass-$version.zip"
helpers="touchglass-pinentry touchglass-scdaemon"

if [ "$dry_run" = 1 ]; then
    identity="-"
    identity_name="ad hoc"
else
    # A release is built from committed sources only, so the tag matches what was signed.
    [ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes; commit or stash them first"
    if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then die "the tag v$version exists already"; fi
    # A release is a commit that main's tests ran for. Fetch first, so origin/main is current.
    git merge-base --is-ancestor HEAD origin/main 2>/dev/null ||
        die "HEAD is not on origin/main; push it to main, run 'git fetch origin', then run this again"
    identity="${TOUCHGLASS_SIGN_IDENTITY:-}"
    identity_name="$identity"
    if [ -z "$identity" ]; then
        # Lines like: 1) <SHA-1> "Developer ID Application: Name (TEAMID)". Signing by SHA-1 stays
        # unambiguous when two certificates share a name.
        identities="$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(Developer ID Application: .*\)"$/\1 \2/p' | sort -u)"
        case "$(printf '%s' "$identities" | grep -c .)" in
            0) die "no Developer ID Application identity in the keychain; set TOUCHGLASS_SIGN_IDENTITY, or pass --dry-run to sign ad hoc" ;;
            1) identity="${identities%% *}"; identity_name="${identities#* }" ;;
            *) die "more than one Developer ID Application identity; pick one with TOUCHGLASS_SIGN_IDENTITY:
$identities" ;;
        esac
    fi
    if [ "$notarize" = 1 ]; then
        xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found; install Xcode or the Command Line Tools"
    fi
fi

step "Build TouchGlass $version for arm64 and x86_64"
# A scratch path of its own, so the universal build leaves the development build in .build alone.
build_args="-c release --arch arm64 --arch x86_64 --scratch-path build/universal"
for product in TouchGlass $helpers; do
    # shellcheck disable=SC2086
    swift build $build_args --product "$product"
done
# shellcheck disable=SC2086
TOUCHGLASS_VERSION="$version" scripts/build-app.sh --prebuilt "$(swift build $build_args --show-bin-path)"
for exe in TouchGlass $helpers; do
    archs=" $(lipo -archs "build/TouchGlass.app/Contents/MacOS/$exe") "
    case "$archs" in *" arm64 "*) ;; *) die "$exe is built without arm64:$archs" ;; esac
    case "$archs" in *" x86_64 "*) ;; *) die "$exe is built without x86_64:$archs" ;; esac
done
rm -rf "$out"
mkdir -p "$out"
ditto build/TouchGlass.app "$app"

step "Sign: $identity_name"
if [ "$identity" = "-" ]; then timestamp="--timestamp=none"; else timestamp="--timestamp"; fi
# Inside out: the helpers first, then the app, whose signature seals them. No entitlements: the app
# runs outside the App Sandbox and needs no hardened runtime exception.
for helper in $helpers; do
    codesign --force --options runtime "$timestamp" --sign "$identity" \
        --identifier "io.ambroos.touchglass.$helper" "$app/Contents/MacOS/$helper"
done
codesign --force --options runtime "$timestamp" --sign "$identity" "$app"

step "Verify signatures"
codesign --verify --deep --strict --verbose=2 "$app"
for exe in TouchGlass $helpers; do
    flags="$(codesign -d --verbose=2 "$app/Contents/MacOS/$exe" 2>&1 | sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-f]*\)(\([^)]*\)).*/\2/p')"
    case "$flags" in
        *runtime*) printf '%s: hardened runtime (%s)\n' "$exe" "$flags" ;;
        *) die "$exe is signed without the hardened runtime" ;;
    esac
done

if [ "$notarize" = 0 ]; then
    step "Skip notarization"
    ditto -c -k --keepParent "$app" "$zip"
else
    step "Notarize with keychain profile $profile"
    ditto -c -k --keepParent "$app" "$out/notarize.zip"
    result="$out/notarytool.json"
    xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait --output-format json > "$result" ||
        die "notarytool submit failed; see $result"
    status="$(plutil -extract status raw -o - "$result")"
    if [ "$status" != Accepted ]; then
        id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
        die "notarization status is $status; run: xcrun notarytool log $id --keychain-profile $profile"
    fi
    rm -f "$out/notarize.zip"

    step "Staple"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    # Gatekeeper's verdict as on a user's Mac: notarized, Developer ID, ticket stapled.
    spctl --assess --verbose=4 --type execute "$app"
    ditto -c -k --keepParent "$app" "$zip"
fi

sha="$(shasum -a 256 "$zip" | awk '{ print $1 }')"
step "Done"
printf 'Zip:     %s\n' "$root/$zip"
printf 'SHA-256: %s\n' "$sha"
if [ "$notarize" = 0 ]; then
    printf '\nNot notarized: Gatekeeper rejects this zip; do not publish it.\n'
    exit 0
fi
cat <<EOF

Next steps:

  git tag v$version && git push origin v$version

The tag push starts a Tests run. Wait until it passes; gh run watch lets you pick it:

  gh run watch --exit-status

Then create the GitHub release:

  gh release create v$version "$root/$zip" --title "TouchGlass $version" --generate-notes

Then run the Release workflow in homebrew-touchglass. It updates the formula to the tag and
publishes its bottle:

  gh workflow run release.yml -R ambroos/homebrew-touchglass -f version=$version

SHA-256 of the zip, for the release notes: $sha
EOF
