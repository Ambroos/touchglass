#!/bin/sh
# Tests scripts/touchglass in sandboxes. Every test runs with a temporary HOME and GNUPGHOME and stub
# gpgconf, pgrep and pkill commands on PATH that record their arguments, so no test reads or writes the
# real GnuPG home, ~/Applications or Application Support, or stops the real gpg-agent, scdaemon or
# TouchGlass host.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tool="$root/scripts/touchglass"
base="$(mktemp -d "${TMPDIR:-/tmp}/touchglass-tests.XXXXXX")"
trap 'rm -rf "$base"' EXIT
failures=0
count=0

fail() { printf '    FAIL: %s\n' "$*"; failures=$((failures + 1)); }
check() { # description command...
    desc="$1"; shift
    if "$@"; then :; else fail "$desc"; fi
}

# Sets up a fresh sandbox in $T and exports HOME, GNUPGHOME and PATH into it.
sandbox() {
    count=$((count + 1))
    T="$base/t$count"
    mkdir -p "$T/home" "$T/gnupg" "$T/bin" "$T/brew/Cellar/gnupg/9.9/libexec" "$T/brew/libexec"
    chmod 700 "$T/gnupg"
    # A fake TouchGlass.app with the three executables and an Info.plist.
    app="$T/src/TouchGlass.app"
    mkdir -p "$app/Contents/MacOS"
    for exe in TouchGlass touchglass-pinentry touchglass-scdaemon; do
        printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/$exe"
        chmod +x "$app/Contents/MacOS/$exe"
    done
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.1.0</string></dict></plist>
PLIST
    # A Homebrew-style scdaemon: a versioned Cellar path plus a stable link to it.
    printf '#!/bin/sh\nexit 0\n' > "$T/brew/Cellar/gnupg/9.9/libexec/scdaemon"
    chmod +x "$T/brew/Cellar/gnupg/9.9/libexec/scdaemon"
    ln -s ../Cellar/gnupg/9.9/libexec/scdaemon "$T/brew/libexec/scdaemon"
    # Stub gpgconf: records every call, reports the Cellar scdaemon, and reports a pinentry when
    # $T/gpgconf-pinentry names one. --kill fails while $T/gpgconf-kill-fails exists.
    cat > "$T/bin/gpgconf" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/gpgconf.log"
case "\$1" in
    --list-components)
        echo "gpg:OpenPGP:$T/brew/Cellar/gnupg/9.9/bin/gpg"
        echo "gpg-agent:Private Keys:$T/brew/Cellar/gnupg/9.9/bin/gpg-agent"
        echo "scdaemon:Smartcards:$T/brew/Cellar/gnupg/9.9/libexec/scdaemon"
        if [ -f "$T/gpgconf-pinentry" ]; then echo "pinentry:Passphrase Entry:\$(cat "$T/gpgconf-pinentry")"; fi
        ;;
    --kill)
        if [ -e "$T/gpgconf-kill-fails" ]; then exit 1; fi
        ;;
esac
exit 0
EOF
    chmod +x "$T/bin/gpgconf"
    # Stub pgrep and pkill: the host "runs" while $T/host-running exists, and pkill records its call.
    cat > "$T/bin/pgrep" <<EOF
#!/bin/sh
test -e "$T/host-running"
EOF
    cat > "$T/bin/pkill" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/pkill.log"
rm -f "$T/host-running"
EOF
    chmod +x "$T/bin/pgrep" "$T/bin/pkill"
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/pinentry-mac"
    chmod +x "$T/bin/pinentry-mac"
    : > "$T/gpgconf.log"
    : > "$T/pkill.log"
    export HOME="$T/home" GNUPGHOME="$T/gnupg" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    # Only the sandbox's pinentry-mac counts, never one installed on this Mac.
    export TOUCHGLASS_PINENTRY_MAC_DIRS="$T/no-pinentry-here"
    # A UTF-8 locale, where awk rejects bytes that aren't UTF-8 unless the script overrides it.
    export LC_ALL=en_US.UTF-8
    export TMPDIR="$T"
    CONF="$GNUPGHOME/gpg-agent.conf"
    APP="$HOME/Applications/TouchGlass.app"
    SUPPORT="$HOME/Library/Application Support/TouchGlass"
}

tg() { "$tool" "$@" > "$T/out" 2>&1 || { echo "    touchglass $* failed:"; sed 's/^/      /' "$T/out"; return 1; }; }
kills() { grep -c -- '--kill gpg-agent' "$T/gpgconf.log" || true; }
scd_kills() { grep -c -- '--kill scdaemon' "$T/gpgconf.log" || true; }
backups() { ls -1 "$CONF".touchglass-backup-* 2>/dev/null | wc -l | tr -d ' '; }
markers() { grep -c '^# touchglass: ' "$CONF" || true; }
out_has() { grep -qF -- "$1" "$T/out"; }

begin() { printf '%s\n' "- $1"; sandbox; }

begin "fresh: no gpg-agent.conf"
tg install --from "$app"
check "app copied" test -x "$APP/Contents/MacOS/touchglass-pinentry"
printf '%s\n' "# touchglass: created gpg-agent.conf" "# touchglass: added pinentry-program" \
    "pinentry-program $APP/Contents/MacOS/touchglass-pinentry" "# touchglass: added scdaemon-program" \
    "scdaemon-program $APP/Contents/MacOS/touchglass-scdaemon" > "$T/expected"
check "conf as expected" cmp -s "$CONF" "$T/expected"
check "stable scdaemon path written" test "$(cat "$SUPPORT/scdaemon-program")" = "$T/brew/libexec/scdaemon"
check "fallback is pinentry-mac" grep -qx "fallback-pinentry = $T/bin/pinentry-mac" "$SUPPORT/pinentry.conf"
check "no host-app line" sh -c "! grep -q host-app '$SUPPORT/pinentry.conf'"
check "support dir is private" test "$(stat -f %Lp "$SUPPORT")" = 700
check "agent reloaded once" test "$(kills)" = 1
check "output mentions forgotten PINs" out_has "forgot its cached PINs"
check "no backup of a missing file" test "$(backups)" = 0
check "default ~/.gnupg untouched" test ! -e "$HOME/.gnupg"
tg uninstall
check "conf removed again" test ! -e "$CONF"
check "agent reloaded twice" test "$(kills)" = 2
check "names the support files it keeps" out_has "Kept $SUPPORT"

begin "existing pinentry-program"
printf '%s\n' "default-cache-ttl 600" "pinentry-program /opt/example/bin/pinentry-mac" "enable-ssh-support" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
printf '%s\n' "# touchglass: added scdaemon-program" "scdaemon-program $APP/Contents/MacOS/touchglass-scdaemon" \
    "default-cache-ttl 600" "# touchglass: pinentry-program /opt/example/bin/pinentry-mac" \
    "pinentry-program $APP/Contents/MacOS/touchglass-pinentry" "enable-ssh-support" > "$T/expected"
check "conf as expected" cmp -s "$CONF" "$T/expected"
check "fallback is the previous pinentry" grep -qx "fallback-pinentry = /opt/example/bin/pinentry-mac" "$SUPPORT/pinentry.conf"
check "one backup" test "$(backups)" = 1
check "backup is the original" cmp -s "$(ls "$CONF".touchglass-backup-*)" "$T/original"
tg uninstall
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"
check "backup kept" test "$(backups)" = 1

begin "comments, odd whitespace, CRLF, duplicates, no final newline"
printf '# pinentry-program /commented/out\n\tpinentry-program   /first/pinentry  \n# a comment\r\n  scdaemon-program\t%s  \r\nkeep-display \t\npinentry-program "/opt/example/bin/pinentry-mac"\r\n\nttyname /dev/null' \
    "$T/brew/Cellar/gnupg/9.9/libexec/scdaemon" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
check "first duplicate untouched" grep -q "^	pinentry-program   /first/pinentry  \$" "$CONF"
check "commented line untouched" grep -qx "# pinentry-program /commented/out" "$CONF"
check "two markers" test "$(markers)" = 2
check "fallback strips quotes" grep -qx "fallback-pinentry = /opt/example/bin/pinentry-mac" "$SUPPORT/pinentry.conf"
check "real scdaemon from the existing line" test "$(cat "$SUPPORT/scdaemon-program")" = "$T/brew/Cellar/gnupg/9.9/libexec/scdaemon"
check "CR kept on the replacement line" grep -q "^pinentry-program $APP/Contents/MacOS/touchglass-pinentry.\$" "$CONF"
check "still no final newline" test "$(tail -c 1 "$CONF")" = "l"
tg uninstall
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "install twice, and install-uninstall-install"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
cp "$CONF" "$T/after-first"
tg install --from "$app"
check "second install changes nothing" cmp -s "$CONF" "$T/after-first"
check "second install says no change" out_has "already points at TouchGlass"
check "one backup" test "$(backups)" = 1
check "no second reload" test "$(kills)" = 1
check "second install restarts scdaemon instead" test "$(scd_kills)" = 1
check "two markers" test "$(markers)" = 2
tg uninstall
tg install --from "$app"
check "same result as the first install" cmp -s "$CONF" "$T/after-first"
check "still one backup" test "$(backups)" = 1
tg uninstall
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "reinstall to another app directory"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" "scdaemon-program /opt/example/libexec/scdaemon" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
tg install --from "$app" --app-dir "$T/elsewhere"
check "paths moved" grep -qx "pinentry-program $T/elsewhere/TouchGlass.app/Contents/MacOS/touchglass-pinentry" "$CONF"
check "two markers" test "$(markers)" = 2
check "one backup" test "$(backups)" = 1
check "real scdaemon from the original line" test "$(cat "$SUPPORT/scdaemon-program")" = "/opt/example/libexec/scdaemon"
tg uninstall --remove-app
check "app in the new directory removed" test ! -e "$T/elsewhere/TouchGlass.app"
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "uninstall after the app was removed"
printf '%s\n' "allow-loopback-pinentry" "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
rm -rf "$APP"
tg uninstall --remove-app
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"
check "says nothing to remove" out_has "nothing to remove"

begin "uninstall --remove-app"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
tg install --from "$app"
tg uninstall --remove-app
check "app removed" test ! -e "$APP"
check "source app untouched" test -x "$app/Contents/MacOS/TouchGlass"

begin "uninstall with no markers falls back to the newest backup"
printf '%s\n' "default-cache-ttl 600" "pinentry-program /opt/example/bin/pinentry-mac" "max-cache-ttl 7200" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
grep -v '^# touchglass: ' "$CONF" > "$T/stripped"; cat "$T/stripped" > "$CONF"
tg uninstall
check "pinentry line restored from the backup" grep -qx "pinentry-program /opt/example/bin/pinentry-mac" "$CONF"
check "scdaemon line removed (backup had none)" sh -c "! grep -q scdaemon-program '$CONF'"
check "explains the fallback" out_has "restore it from"
# The original had pinentry-program on line 2; without markers the restored line stays where the TouchGlass line was.
check "same lines as the original" test "$(sort "$CONF")" = "$(sort "$T/original")"

begin "uninstall with no markers and no backup"
printf '%s\n' "default-cache-ttl 600" "pinentry-program /x/TouchGlass.app/Contents/MacOS/touchglass-pinentry" > "$CONF"
tg uninstall
check "TouchGlass line removed" test "$(cat "$CONF")" = "default-cache-ttl 600"
check "warns about the default" out_has "gpg-agent uses its default"

begin "dry run writes nothing"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app" --dry-run
check "conf unchanged" cmp -s "$CONF" "$T/original"
check "no app copied" test ! -e "$APP"
check "no support files" test ! -e "$SUPPORT"
check "no backup" test "$(backups)" = 0
check "no reload" test "$(kills)" = 0
check "prints the diff" out_has "+# touchglass: pinentry-program /opt/example/bin/pinentry-mac"
check "prints the removed line" out_has "-pinentry-program /opt/example/bin/pinentry-mac"
check "mentions forgotten PINs" out_has "forgets cached PINs"
tg install --from "$app"
cp "$CONF" "$T/installed"
tg uninstall --dry-run --remove-app
check "conf unchanged by uninstall dry run" cmp -s "$CONF" "$T/installed"
check "app still there" test -x "$APP/Contents/MacOS/TouchGlass"
check "uninstall dry run prints the restore" out_has "+pinentry-program /opt/example/bin/pinentry-mac"
check "one reload only (from the real install)" test "$(kills)" = 1

begin "status"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
tg status
check "shows the plain pinentry" out_has "pinentry-program:  /opt/example/bin/pinentry-mac"
check "shows no backups" out_has "Backups:           none"
tg install --from "$app"
tg status
check "shows the TouchGlass pinentry" out_has "touchglass-pinentry (TouchGlass)"
check "shows the TouchGlass scdaemon" out_has "touchglass-scdaemon (TouchGlass)"
check "shows the version" out_has "(version 0.1.0)"
check "shows host state" grep -qE "Host: +(running|not running)" "$T/out"
check "lists the backup" out_has "gpg-agent.conf.touchglass-backup-"

begin "rejects an app path with spaces"
if "$tool" install --from "$app" --app-dir "$T/with space" > "$T/out" 2>&1; then fail "accepted a path with a space"; fi
check "conf not created" test ! -e "$CONF"

begin "reinstall replaces the app, restarts scdaemon and quits the host"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
tg install --from "$app"
check "first install quits no host" test ! -s "$T/pkill.log"
check "first install leaves scdaemon to the agent reload" test "$(scd_kills)" = 0
touch "$T/host-running"
printf '#!/bin/sh\necho new\n' > "$app/Contents/MacOS/touchglass-scdaemon"
tg install --from "$app" --dry-run
check "dry run names the host quit" out_has "Would quit the running TouchGlass host with 'pkill -x TouchGlass'"
check "dry run names the scdaemon stop" out_has "Would then stop scdaemon with 'gpgconf --kill scdaemon'"
check "dry run quits nothing" test ! -s "$T/pkill.log"
check "dry run stops nothing" test "$(scd_kills)" = 0
tg install --from "$app"
check "new helper copied" grep -q new "$APP/Contents/MacOS/touchglass-scdaemon"
check "host quit" grep -qx -- "-x TouchGlass" "$T/pkill.log"
check "scdaemon stopped once" test "$(scd_kills)" = 1
check "agent not stopped again" test "$(kills)" = 1
check "says the PIN is asked again" out_has "asks for the PIN again"
check "no copy left behind" test ! -e "$APP.new" -a ! -e "$APP.old"

begin "a failed copy leaves the installed app and gpg-agent.conf alone"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
tg install --from "$app"
cp "$CONF" "$T/installed"
printf '#!/bin/sh\nmkdir -p "$2/Contents"; exit 1\n' > "$T/bin/ditto"
chmod +x "$T/bin/ditto"
if "$tool" install --from "$app" > "$T/out" 2>&1; then fail "install succeeded although the copy failed"; fi
rm "$T/bin/ditto"
check "explains the failure" out_has "is unchanged"
check "installed app intact" test -x "$APP/Contents/MacOS/touchglass-pinentry"
check "partial copy removed" test ! -e "$APP.new"
check "conf unchanged" cmp -s "$CONF" "$T/installed"
check "nothing stopped" test "$(scd_kills)" = 0

begin "bytes that aren't UTF-8 in gpg-agent.conf"
printf 'default-cache-ttl 600\n# caf\351 in Latin-1\npinentry-program /opt/example/bin/pinentry-mac\n' > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
check "installed" grep -q "touchglass-pinentry" "$CONF"
check "Latin-1 line kept" env LC_ALL=C grep -q "$(printf 'caf\351')" "$CONF"
tg uninstall
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "no pinentry-mac: the fallback comes from gpgconf"
rm "$T/bin/pinentry-mac"
printf '#!/bin/sh\nexit 0\n' > "$T/brew/pinentry-curses"
chmod +x "$T/brew/pinentry-curses"
printf '%s' "$T/brew/pinentry-curses" > "$T/gpgconf-pinentry"
printf '%s\n' "enable-ssh-support" > "$CONF"
tg install --from "$app"
check "fallback is gpgconf's pinentry" grep -qx "fallback-pinentry = $T/brew/pinentry-curses" "$SUPPORT/pinentry.conf"

begin "no pinentry at all: no fallback path that doesn't exist"
rm "$T/bin/pinentry-mac"
printf '%s\n' "enable-ssh-support" > "$CONF"
tg install --from "$app"
check "warns" out_has "no pinentry found"
check "no fallback-pinentry setting" sh -c "! grep -q '^fallback-pinentry' '$SUPPORT/pinentry.conf'"

begin "reinstall cleans up an earlier pinentry.conf"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
mkdir -p "$SUPPORT"
printf '%s\n' '# touchglass-pinentry settings. One "key = value" per line.' "fallback-pinentry = $T/gone/pinentry-mac" \
    '# The app the pinentry starts when the host is not running; "none" disables starting it.' "host-app = $T/old/TouchGlass.app" "log-file = $T/pinentry.log" > "$SUPPORT/pinentry.conf"
tg install --from "$app"
check "stale fallback replaced" grep -qx "fallback-pinentry = /opt/example/bin/pinentry-mac" "$SUPPORT/pinentry.conf"
check "host-app removed" sh -c "! grep -q host-app '$SUPPORT/pinentry.conf'"
check "other settings kept" grep -qx "log-file = $T/pinentry.log" "$SUPPORT/pinentry.conf"
printf '%s\n' "fallback-pinentry = $T/bin/pinentry-mac" "host-app = none" > "$SUPPORT/pinentry.conf"
tg install --from "$app"
check "a working fallback and host-app = none stay" test "$(cat "$SUPPORT/pinentry.conf")" = "$(printf '%s\n' "fallback-pinentry = $T/bin/pinentry-mac" "host-app = none")"

begin "missing GnuPG home is created private"
rmdir "$GNUPGHOME"
tg install --from "$app"
check "GnuPG home mode 700" test "$(stat -f %Lp "$GNUPGHOME")" = 700

begin "symlinked gpg-agent.conf keeps its link and mode"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$T/real.conf"
chmod 640 "$T/real.conf"
cp "$T/real.conf" "$T/original"
ln -s "$T/real.conf" "$CONF"
tg install --from "$app"
check "still a link" test -L "$CONF"
check "target changed" grep -q touchglass-pinentry "$T/real.conf"
check "target mode kept" test "$(stat -f %Lp "$T/real.conf")" = 640
check "no staging file left" test -z "$(ls -A "$T" | grep '^\.gpg-agent.conf.touchglass' || true)"
tg uninstall
check "round trip is byte-identical" cmp -s "$T/real.conf" "$T/original"
check "still a link after uninstall" test -L "$CONF"

begin "a failing gpgconf --kill is reported"
printf '%s\n' "pinentry-program /opt/example/bin/pinentry-mac" > "$CONF"
touch "$T/gpgconf-kill-fails"
if "$tool" install --from "$app" > "$T/out" 2>&1; then fail "install exited 0 although gpgconf --kill failed"; fi
check "warns that the conf is written" out_has "gpg-agent.conf is written, but 'gpgconf --kill gpg-agent' failed"
check "conf written" grep -q touchglass-pinentry "$CONF"
if "$tool" uninstall > "$T/out" 2>&1; then fail "uninstall exited 0 although gpgconf --kill failed"; fi
check "uninstall warns too" out_has "'gpgconf --kill gpg-agent' failed"

printf '\n%d sandboxes, %d failures\n' "$count" "$failures"
[ "$failures" = 0 ]
