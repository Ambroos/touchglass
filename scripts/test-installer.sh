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
    # Stub pgrep, ps and pkill. The host "runs" while $T/host-running exists, another process while
    # $T/running-<name> exists. gpg-agent runs as PID 4242 while $T/agent-etime exists, and ps reports
    # that file's content as its elapsed time. pkill records its call.
    cat > "$T/bin/pgrep" <<EOF
#!/bin/sh
for name in "\$@"; do :; done
case "\$name" in
    TouchGlass) test -e "$T/host-running" ;;
    gpg-agent) test -e "$T/agent-etime" && echo 4242 ;;
    *) test -e "$T/running-\$name" ;;
esac
EOF
    cat > "$T/bin/ps" <<EOF
#!/bin/sh
cat "$T/agent-etime"
EOF
    chmod +x "$T/bin/ps"
    cat > "$T/bin/pkill" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/pkill.log"
rm -f "$T/host-running"
EOF
    chmod +x "$T/bin/pgrep" "$T/bin/pkill"
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/pinentry-mac"
    chmod +x "$T/bin/pinentry-mac"
    # The pinentry that the tests' gpg-agent.conf names before TouchGlass.
    EX="$T/example/bin/pinentry-mac"
    mkdir -p "$T/example/bin"
    printf '#!/bin/sh\nexit 0\n' > "$EX"
    chmod +x "$EX"
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
    LP="$SUPPORT/bin/touchglass-pinentry"
    LS="$SUPPORT/bin/touchglass-scdaemon"
}

tg() { "$tool" "$@" > "$T/out" 2>&1 || { echo "    touchglass $* failed:"; sed 's/^/      /' "$T/out"; return 1; }; }
kills() { grep -c -- '--kill gpg-agent' "$T/gpgconf.log" || true; }
scd_kills() { grep -c -- '--kill scdaemon' "$T/gpgconf.log" || true; }
backups() { ls -1 "$CONF".touchglass-backup-* 2>/dev/null | wc -l | tr -d ' '; }
markers() { grep -c '^# touchglass: ' "$CONF" || true; }
out_has() { grep -qF -- "$1" "$T/out"; }

begin() { printf '%s\n' "- $1"; sandbox; }

begin "fresh: no gpg-agent.conf"
tg install --apply --from "$app"
check "app copied" test -x "$APP/Contents/MacOS/touchglass-pinentry"
printf '%s\n' "# touchglass: created gpg-agent.conf" "# touchglass: added pinentry-program" \
    "pinentry-program $LP" "# touchglass: added scdaemon-program" \
    "scdaemon-program $LS" > "$T/expected"
check "conf as expected" cmp -s "$CONF" "$T/expected"
check "stable scdaemon path written" test "$(cat "$SUPPORT/scdaemon-program")" = "$T/brew/libexec/scdaemon"
check "fallback is pinentry-mac" grep -qx "fallback-pinentry = $T/bin/pinentry-mac" "$SUPPORT/pinentry.conf"
check "no host-app line" sh -c "! grep -q host-app '$SUPPORT/pinentry.conf'"
check "support dir is private" test "$(stat -f %Lp "$SUPPORT")" = 700
check "agent reloaded once" test "$(kills)" = 1
check "output mentions forgotten PINs" out_has "forgot its cached PINs"
check "no backup of a missing file" test "$(backups)" = 0
check "default ~/.gnupg untouched" test ! -e "$HOME/.gnupg"
tg uninstall --apply
check "conf removed again" test ! -e "$CONF"
check "agent reloaded twice" test "$(kills)" = 2
check "names the support files it keeps" out_has "Kept $SUPPORT"

begin "existing pinentry-program"
printf '%s\n' "default-cache-ttl 600" "pinentry-program $EX" "enable-ssh-support" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
printf '%s\n' "default-cache-ttl 600" "# touchglass: pinentry-program $EX" \
    "pinentry-program $LP" "enable-ssh-support" \
    "# touchglass: added scdaemon-program" "scdaemon-program $LS" > "$T/expected"
check "conf as expected" cmp -s "$CONF" "$T/expected"
check "fallback is the previous pinentry" grep -qx "fallback-pinentry = $EX" "$SUPPORT/pinentry.conf"
check "one backup" test "$(backups)" = 1
check "backup is the original" cmp -s "$(ls "$CONF".touchglass-backup-*)" "$T/original"
tg uninstall --apply
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"
check "backup kept" test "$(backups)" = 1

begin "comments, odd whitespace, CRLF, duplicates, no final newline"
printf '# pinentry-program /commented/out\n\tpinentry-program   /first/pinentry  \n# a comment\r\n  scdaemon-program\t%s  \r\nkeep-display \t\npinentry-program "%s"\r\n\nttyname /dev/null' \
    "$T/brew/Cellar/gnupg/9.9/libexec/scdaemon" "$EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
check "first duplicate untouched" grep -q "^	pinentry-program   /first/pinentry  \$" "$CONF"
check "commented line untouched" grep -qx "# pinentry-program /commented/out" "$CONF"
check "two markers" test "$(markers)" = 2
check "fallback strips quotes" grep -qx "fallback-pinentry = $EX" "$SUPPORT/pinentry.conf"
check "real scdaemon from the existing line" test "$(cat "$SUPPORT/scdaemon-program")" = "$T/brew/Cellar/gnupg/9.9/libexec/scdaemon"
check "CR kept on the replacement line" grep -q "^pinentry-program $LP.\$" "$CONF"
check "still no final newline" test "$(tail -c 1 "$CONF")" = "l"
tg uninstall --apply
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "install twice, and install-uninstall-install"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
cp "$CONF" "$T/after-first"
tg install --apply --from "$app"
check "second install changes nothing" cmp -s "$CONF" "$T/after-first"
check "second install says no change" out_has "already uses the TouchGlass launchers"
check "one backup" test "$(backups)" = 1
check "no second reload" test "$(kills)" = 1
check "second install restarts scdaemon instead" test "$(scd_kills)" = 1
check "two markers" test "$(markers)" = 2
tg uninstall --apply
tg install --apply --from "$app"
check "same result as the first install" cmp -s "$CONF" "$T/after-first"
check "still one backup" test "$(backups)" = 1
tg uninstall --apply
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "reinstall to another app directory"
printf '%s\n' "pinentry-program $EX" "scdaemon-program /opt/example/libexec/scdaemon" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
tg install --apply --from "$app" --app-dir "$T/elsewhere"
check "conf still names the launchers" grep -qx "pinentry-program $LP" "$CONF"
check "launchers moved to the new app" grep -qx "app='$T/elsewhere/TouchGlass.app'" "$LP"
check "two markers" test "$(markers)" = 2
check "one backup" test "$(backups)" = 1
check "real scdaemon from the original line" test "$(cat "$SUPPORT/scdaemon-program")" = "/opt/example/libexec/scdaemon"
tg uninstall --apply --remove-app
check "app in the new directory removed" test ! -e "$T/elsewhere/TouchGlass.app"
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "uninstall after the app was removed"
printf '%s\n' "allow-loopback-pinentry" "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
rm -rf "$APP"
tg uninstall --apply --remove-app
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"
check "says nothing to remove" out_has "nothing to remove"

begin "uninstall --remove-app"
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg install --apply --from "$app"
tg uninstall --apply --remove-app
check "app removed" test ! -e "$APP"
check "source app untouched" test -x "$app/Contents/MacOS/TouchGlass"

begin "uninstall with no markers falls back to the newest backup"
printf '%s\n' "default-cache-ttl 600" "pinentry-program $EX" "max-cache-ttl 7200" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
grep -v '^# touchglass: ' "$CONF" > "$T/stripped"; cat "$T/stripped" > "$CONF"
tg uninstall --apply
check "pinentry line restored from the backup" grep -qx "pinentry-program $EX" "$CONF"
check "scdaemon line removed (backup had none)" sh -c "! grep -q scdaemon-program '$CONF'"
check "explains the fallback" out_has "restore it from"
# The original had pinentry-program on line 2; without markers the restored line stays where the TouchGlass line was.
check "same lines as the original" test "$(sort "$CONF")" = "$(sort "$T/original")"

begin "uninstall with no markers and no backup"
printf '%s\n' "default-cache-ttl 600" "pinentry-program /x/TouchGlass.app/Contents/MacOS/touchglass-pinentry" > "$CONF"
tg uninstall --apply
check "TouchGlass line removed" test "$(cat "$CONF")" = "default-cache-ttl 600"
check "warns about the default" out_has "gpg-agent uses its default"

begin "dry run writes nothing"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app" --dry-run
check "conf unchanged" cmp -s "$CONF" "$T/original"
check "no app copied" test ! -e "$APP"
check "no support files" test ! -e "$SUPPORT"
check "no backup" test "$(backups)" = 0
check "no reload" test "$(kills)" = 0
check "prints the diff" out_has "+# touchglass: pinentry-program $EX"
check "prints the removed line" out_has "-pinentry-program $EX"
check "mentions forgotten PINs" out_has "forgets cached PINs"
tg install --apply --from "$app"
cp "$CONF" "$T/installed"
tg uninstall --apply --dry-run --remove-app
check "conf unchanged by uninstall dry run" cmp -s "$CONF" "$T/installed"
check "app still there" test -x "$APP/Contents/MacOS/TouchGlass"
check "uninstall dry run prints the restore" out_has "+pinentry-program $EX"
check "one reload only (from the real install)" test "$(kills)" = 1

begin "status"
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg status
check "shows the plain pinentry" out_has "pinentry-program:  $EX"
check "shows no backups" out_has "Backups:           none"
tg install --apply --from "$app"
tg status
check "shows the pinentry launcher" out_has "touchglass-pinentry (TouchGlass launcher)"
check "shows the scdaemon launcher" out_has "touchglass-scdaemon (TouchGlass launcher)"
check "says it uses the launchers" out_has "runs TouchGlass through the launchers"
check "shows where the launchers lead" out_has "running $APP"
check "shows the version" out_has "(version 0.1.0)"
check "shows host state" grep -qE "Host: +(running|not running)" "$T/out"
check "lists the backup" out_has "gpg-agent.conf.touchglass-backup-"

begin "an app path with spaces works through the launchers"
tg install --apply --from "$app" --app-dir "$T/with space"
check "app copied" test -x "$T/with space/TouchGlass.app/Contents/MacOS/touchglass-pinentry"
check "launcher records the path" grep -qx "app='$T/with space/TouchGlass.app'" "$LP"
check "conf names the launcher" grep -qx "pinentry-program $LP" "$CONF"

begin "reinstall replaces the app, restarts scdaemon and quits the host"
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg install --apply --from "$app"
check "first install quits no host" test ! -s "$T/pkill.log"
check "first install leaves scdaemon to the agent reload" test "$(scd_kills)" = 0
touch "$T/host-running"
printf '#!/bin/sh\necho new\n' > "$app/Contents/MacOS/touchglass-scdaemon"
tg install --apply --from "$app" --dry-run
check "dry run names the host quit" out_has "Would quit the running TouchGlass host with 'pkill -x TouchGlass'"
check "dry run names the scdaemon stop" out_has "Would then stop scdaemon with 'gpgconf --kill scdaemon'"
check "dry run quits nothing" test ! -s "$T/pkill.log"
check "dry run stops nothing" test "$(scd_kills)" = 0
tg install --apply --from "$app"
check "new helper copied" grep -q new "$APP/Contents/MacOS/touchglass-scdaemon"
check "host quit" grep -qx -- "-x TouchGlass" "$T/pkill.log"
check "scdaemon stopped once" test "$(scd_kills)" = 1
check "agent not stopped again" test "$(kills)" = 1
check "says the PIN is asked again" out_has "asks for the PIN again"
check "no copy left behind" test ! -e "$APP.new" -a ! -e "$APP.old"

begin "a failed copy leaves the installed app and gpg-agent.conf alone"
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg install --apply --from "$app"
cp "$CONF" "$T/installed"
printf '#!/bin/sh\nmkdir -p "$2/Contents"; exit 1\n' > "$T/bin/ditto"
chmod +x "$T/bin/ditto"
if "$tool" install --apply --from "$app" > "$T/out" 2>&1; then fail "install succeeded although the copy failed"; fi
rm "$T/bin/ditto"
check "explains the failure" out_has "is unchanged"
check "installed app intact" test -x "$APP/Contents/MacOS/touchglass-pinentry"
check "partial copy removed" test ! -e "$APP.new"
check "conf unchanged" cmp -s "$CONF" "$T/installed"
check "nothing stopped" test "$(scd_kills)" = 0

begin "bytes that aren't UTF-8 in gpg-agent.conf"
printf 'default-cache-ttl 600\n# caf\351 in Latin-1\npinentry-program %s\n' "$EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
check "installed" grep -q "touchglass-pinentry" "$CONF"
check "Latin-1 line kept" env LC_ALL=C grep -q "$(printf 'caf\351')" "$CONF"
tg uninstall --apply
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"

begin "no pinentry-mac: the fallback comes from gpgconf"
rm "$T/bin/pinentry-mac"
printf '#!/bin/sh\nexit 0\n' > "$T/brew/pinentry-curses"
chmod +x "$T/brew/pinentry-curses"
printf '%s' "$T/brew/pinentry-curses" > "$T/gpgconf-pinentry"
printf '%s\n' "enable-ssh-support" > "$CONF"
tg install --apply --from "$app"
check "fallback is gpgconf's pinentry" grep -qx "fallback-pinentry = $T/brew/pinentry-curses" "$SUPPORT/pinentry.conf"

begin "no pinentry at all: no fallback path that doesn't exist"
rm "$T/bin/pinentry-mac"
printf '%s\n' "enable-ssh-support" > "$CONF"
tg install --apply --from "$app"
check "warns" out_has "no pinentry found"
check "no fallback-pinentry setting" sh -c "! grep -q '^fallback-pinentry' '$SUPPORT/pinentry.conf'"

begin "reinstall cleans up an earlier pinentry.conf"
printf '%s\n' "pinentry-program $EX" > "$CONF"
mkdir -p "$SUPPORT"
printf '%s\n' '# touchglass-pinentry settings. One "key = value" per line.' "fallback-pinentry = $T/gone/pinentry-mac" \
    '# The app the pinentry starts when the host is not running; "none" disables starting it.' "host-app = $T/old/TouchGlass.app" "log-file = $T/pinentry.log" > "$SUPPORT/pinentry.conf"
tg install --apply --from "$app"
check "stale fallback replaced" grep -qx "fallback-pinentry = $EX" "$SUPPORT/pinentry.conf"
check "host-app removed" sh -c "! grep -q host-app '$SUPPORT/pinentry.conf'"
check "other settings kept" grep -qx "log-file = $T/pinentry.log" "$SUPPORT/pinentry.conf"
printf '%s\n' "fallback-pinentry = $T/bin/pinentry-mac" "host-app = none" > "$SUPPORT/pinentry.conf"
tg install --apply --from "$app"
check "a working fallback and host-app = none stay" test "$(cat "$SUPPORT/pinentry.conf")" = "$(printf '%s\n' "fallback-pinentry = $T/bin/pinentry-mac" "host-app = none")"

begin "missing GnuPG home is created private"
rmdir "$GNUPGHOME"
tg install --apply --from "$app"
check "GnuPG home mode 700" test "$(stat -f %Lp "$GNUPGHOME")" = 700

begin "symlinked gpg-agent.conf keeps its link and mode"
printf '%s\n' "pinentry-program $EX" > "$T/real.conf"
chmod 640 "$T/real.conf"
cp "$T/real.conf" "$T/original"
ln -s "$T/real.conf" "$CONF"
tg install --apply --from "$app"
check "still a link" test -L "$CONF"
check "target changed" grep -q touchglass-pinentry "$T/real.conf"
check "target mode kept" test "$(stat -f %Lp "$T/real.conf")" = 640
check "no staging file left" test -z "$(ls -A "$T" | grep '^\.gpg-agent.conf.touchglass' || true)"
tg uninstall --apply
check "round trip is byte-identical" cmp -s "$T/real.conf" "$T/original"
check "still a link after uninstall" test -L "$CONF"

# A stub executable that prints its name, its arguments and its PID, then copies stdin to stdout.
echo_stub() { # path name
    printf '#!/bin/sh\necho "%s pid=$$ args=$*"\necho "%s launcher=${TOUCHGLASS_LAUNCHER-unset}"\ncat\n' "$2" "$2" > "$1"
    chmod +x "$1"
}

begin "manual install prints the change and leaves gpg-agent.conf alone"
printf '%s\n' "default-cache-ttl 600" "pinentry-program $EX" "pinentry-program /opt/example/bin/pinentry-other" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
check "conf unchanged" cmp -s "$CONF" "$T/original"
check "no backup" test "$(backups)" = 0
check "no reload" test "$(kills)" = 0
check "pinentry launcher written" test -x "$LP"
check "scdaemon launcher written" test -x "$LS"
check "CLI copied next to the launchers" cmp -s "$SUPPORT/bin/touchglass" "$tool"
check "names the file" out_has "Edit $CONF:"
check "replaces the effective line" out_has "Replace line 3:"
check "keeps it as a marked comment" out_has "    # touchglass: pinentry-program /opt/example/bin/pinentry-other"
check "leaves the earlier duplicate alone" sh -c "! grep -q 'line 2' '$T/out'"
check "prints the pinentry line" out_has "    pinentry-program $LP"
check "adds the scdaemon marker" out_has "    # touchglass: added scdaemon-program"
check "prints the scdaemon line" out_has "    scdaemon-program $LS"
check "prints the reload command" out_has "gpgconf --kill gpg-agent"
check "says PINs are forgotten" out_has "forgets its cached PINs"
check "offers --apply" out_has "touchglass install --apply"
tg status
check "status: not used yet" out_has "doesn't use TouchGlass"
# Make the change the way the instructions say, then check that install sees it as done.
printf '%s\n' "default-cache-ttl 600" "pinentry-program $EX" "# touchglass: pinentry-program /opt/example/bin/pinentry-other" \
    "pinentry-program $LP" "# touchglass: added scdaemon-program" "scdaemon-program $LS" > "$CONF"
cp "$CONF" "$T/edited"
tg install --from "$app"
check "second run sees the launchers" out_has "already uses the TouchGlass launchers"
check "second run prints no steps" sh -c "! grep -q 'Edit ' '$T/out'"
check "conf still as edited" cmp -s "$CONF" "$T/edited"
tg status
check "status: uses the launchers" out_has "runs TouchGlass through the launchers"
tg uninstall --apply
check "uninstall --apply restores the original" cmp -s "$CONF" "$T/original"
check "no backup involved" test "$(backups)" = 0

begin "manual install as printed, then uninstall --apply"
printf '%s\n' "default-cache-ttl 600" "  pinentry-program $EX" "scdaemon-program /opt/example/libexec/scdaemon" "enable-ssh-support" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
# Apply the printed steps literally: each "Replace line N:" block's two lines take the place of line N,
# and the lines under "Add these lines" go at the end.
awk -v conf="$CONF" '
    /^  Replace line [0-9]+:$/ { n = $3 + 0; sub(/:$/, "", n); mode = "r"; got = 0; next }
    /^  with these two lines/ { mode = "w"; next }
    /^  Add these lines/ { mode = "a"; next }
    /^$/ { mode = "" }
    mode == "w" && /^    / { with[n] = with[n] substr($0, 5) "\n"; next }
    mode == "a" && /^    / { add = add substr($0, 5) "\n"; next }
    END {
        while ((getline line < conf) > 0) { i++; if (i in with) printf "%s", with[i]; else print line }
        printf "%s", add
    }' "$T/out" > "$T/edited"
cp "$T/edited" "$CONF"
check "manual edit has both markers" test "$(grep -c '^# touchglass: ' "$CONF")" = 2
tg uninstall --apply
check "uninstall --apply restores the original" cmp -s "$CONF" "$T/original"

begin "manual install that adds lines, as printed, equals install --apply"
printf '%s\n' "default-cache-ttl 600" "enable-ssh-support" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app"
check "says to add at the end" out_has "Add these lines at the end of the file."
# Append the lines under "Add these lines" to the file.
{ cat "$CONF"; sed -n '/^  Add these lines/,/^$/s/^    //p' "$T/out"; } > "$T/edited"
tg install --apply --from "$app"
check "manual edit equals what --apply writes" cmp -s "$CONF" "$T/edited"
tg uninstall --apply
check "uninstall --apply restores the original" cmp -s "$CONF" "$T/original"

begin "uninstall --apply stops at an edit made by hand without markers"
printf '%s\n' "default-cache-ttl 600" "#pinentry-program $EX" "pinentry-program $LP" "scdaemon-program $LS" > "$CONF"
cp "$CONF" "$T/edited"
tg install --from "$app"
if "$tool" uninstall --apply > "$T/out" 2>&1; then fail "uninstall --apply exited 0"; fi
check "conf unchanged" cmp -s "$CONF" "$T/edited"
check "no reload" test "$(kills)" = 0
check "launchers kept" test -x "$LP" -a -x "$LS"
check "explains why" out_has "can't tell what to restore, so it changed nothing"
check "points at the commented-out line" out_has "line 2: #pinentry-program $EX"
check "says what to delete" out_has "line 3: pinentry-program $LP"
if "$tool" uninstall --apply --dry-run > "$T/out" 2>&1; then fail "uninstall --apply --dry-run exited 0"; fi
check "dry run stops too" out_has "can't tell what to restore"
check "dry run changes nothing either" cmp -s "$CONF" "$T/edited"

begin "manual install without gpg-agent.conf"
tg install --from "$app"
check "conf not created" test ! -e "$CONF"
check "says to create it" out_has "Create $CONF with these lines."
check "launchers written" test -x "$LP"
# Create it as printed: uninstall --apply then deletes it again.
sed -n 's/^    //p' "$T/out" | sed -n '1,5p' > "$CONF"
check "printed file is what --apply writes" sh -c "head -n 1 '$CONF' | grep -qx '# touchglass: created gpg-agent.conf'"
tg uninstall --apply
check "uninstall --apply deletes it" test ! -e "$CONF"

begin "manual install dry run writes nothing"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --from "$app" --dry-run
check "conf unchanged" cmp -s "$CONF" "$T/original"
check "no support files" test ! -e "$SUPPORT"
check "no app copied" test ! -e "$APP"
check "names the launchers" out_has "Would write the launchers for $APP"
check "shows the steps" out_has "    pinentry-program $LP"

begin "manual reinstall over a newer app kills nothing"
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg install --apply --from "$app"
touch "$T/host-running"
printf '#!/bin/sh\necho new\n' > "$app/Contents/MacOS/touchglass-scdaemon"
tg install --from "$app"
check "new helper copied" grep -q new "$APP/Contents/MacOS/touchglass-scdaemon"
check "host not quit" test ! -s "$T/pkill.log"
check "scdaemon not stopped" test "$(scd_kills)" = 0
check "prints the scdaemon restart" out_has "  gpgconf --kill scdaemon"
check "prints the host quit" out_has "  pkill -x TouchGlass"

begin "launchers run the app's helpers with exec"
tg install --from "$app"
echo_stub "$APP/Contents/MacOS/touchglass-pinentry" helper-pinentry
echo_stub "$APP/Contents/MacOS/touchglass-scdaemon" helper-scdaemon
printf 'OK\n' | sh -c 'echo "launcher pid=$$"; exec "$1" --display :0 "two words"' sh "$LP" > "$T/run"
check "pinentry helper ran with the arguments" grep -q '^helper-pinentry pid=[0-9]* args=--display :0 two words$' "$T/run"
check "pinentry stdin passes through" grep -qx OK "$T/run"
check "same process: exec, no child" test "$(sed -n 's/^launcher pid=//p' "$T/run")" = "$(sed -n 's/^helper-pinentry pid=\([0-9]*\).*/\1/p' "$T/run")"
printf 'GETINFO version\n' | "$LS" --multi-server > "$T/run"
check "scdaemon helper ran with the arguments" grep -q '^helper-scdaemon pid=[0-9]* args=--multi-server$' "$T/run"
check "scdaemon stdin passes through" grep -qx "GETINFO version" "$T/run"
check "the helper learns the launcher format" grep -qx 'helper-scdaemon launcher=1' "$T/run"

begin "launchers fall back while the app is missing"
echo_stub "$T/bin/pinentry-mac" pinentry-mac
echo_stub "$T/brew/Cellar/gnupg/9.9/libexec/scdaemon" real-scdaemon
tg install --from "$app"
rm -rf "$APP"
printf 'GETPIN\n' | "$LP" --ttyname /dev/null > "$T/run"
check "pinentry falls back to pinentry.conf's fallback" grep -q '^pinentry-mac pid=[0-9]* args=--ttyname /dev/null$' "$T/run"
check "fallback gets stdin" grep -qx GETPIN "$T/run"
printf 'SERIALNO\n' | "$LS" --multi-server > "$T/run"
check "scdaemon falls back to the real scdaemon" grep -q '^real-scdaemon pid=[0-9]* args=--multi-server$' "$T/run"
check "real scdaemon gets stdin" grep -qx SERIALNO "$T/run"
check "only the helper gets the launcher format" grep -qx 'real-scdaemon launcher=unset' "$T/run"
# Without pinentry.conf, the pinentry launcher tries pinentry-mac in the default directories.
rm "$SUPPORT/pinentry.conf"
mkdir -p "$T/no-pinentry-here"
echo_stub "$T/no-pinentry-here/pinentry-mac" default-pinentry-mac
printf '' | "$LP" > "$T/run"
check "pinentry falls back to the default pinentry-mac" grep -q '^default-pinentry-mac ' "$T/run"
rm "$T/no-pinentry-here/pinentry-mac" "$SUPPORT/scdaemon-program"
if "$LP" < /dev/null > "$T/run" 2> "$T/err"; then fail "pinentry launcher exited 0 without any pinentry"; fi
check "pinentry launcher explains" grep -q "no fallback pinentry is executable" "$T/err"
if "$LS" < /dev/null > "$T/run" 2> "$T/err"; then fail "scdaemon launcher exited 0 without a real scdaemon"; fi
check "scdaemon launcher explains" grep -q "names no executable scdaemon" "$T/err"

begin "migration from helpers named directly in gpg-agent.conf"
# gpg-agent.conf and backup as installs before the launchers wrote them.
mkdir -p "$HOME/Applications"
ditto "$app" "$APP"
printf '%s\n' "default-cache-ttl 600" "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
cp "$CONF" "$CONF.touchglass-backup-20260101-000000"
printf '%s\n' "# touchglass: added scdaemon-program" "scdaemon-program $APP/Contents/MacOS/touchglass-scdaemon" \
    "default-cache-ttl 600" "# touchglass: pinentry-program $EX" \
    "pinentry-program $APP/Contents/MacOS/touchglass-pinentry" > "$CONF"
cp "$CONF" "$T/direct"
tg status
check "status recognises the direct setup" out_has "runs the helpers in TouchGlass.app directly"
check "status labels the helper" out_has "touchglass-pinentry (TouchGlass helper)"
check "status finds the app" out_has "App:               $APP (version 0.1.0)"
tg install --from "$app"
check "manual install leaves the conf" cmp -s "$CONF" "$T/direct"
check "says to replace the scdaemon line" out_has "Replace line 2, which runs the helper in TouchGlass.app directly:"
check "says to replace the pinentry line" out_has "Replace line 5, which runs the helper in TouchGlass.app directly:"
check "nothing to comment out" sh -c "! grep -q 'Comment out' '$T/out'"
check "nothing to add" sh -c "! grep -q 'Add these lines' '$T/out'"
tg install --apply --from "$app"
printf '%s\n' "# touchglass: added scdaemon-program" "scdaemon-program $LS" \
    "default-cache-ttl 600" "# touchglass: pinentry-program $EX" \
    "pinentry-program $LP" > "$T/expected"
check "--apply switches to the launchers, markers kept" cmp -s "$CONF" "$T/expected"
check "no second backup" test "$(backups)" = 1
check "agent reloaded" test "$(kills)" = 1
check "real scdaemon from gpgconf" test "$(cat "$SUPPORT/scdaemon-program")" = "$T/brew/libexec/scdaemon"
check "fallback from the marker" grep -qx "fallback-pinentry = $EX" "$SUPPORT/pinentry.conf"
tg uninstall --apply
check "uninstall restores the pre-TouchGlass file" cmp -s "$CONF" "$T/original"
check "launchers removed" test ! -e "$SUPPORT/bin"

begin "manual uninstall prints the revert and keeps the launchers"
printf '%s\n' "default-cache-ttl 600" "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
cp "$CONF" "$T/installed"
tg uninstall --remove-app
check "conf unchanged" cmp -s "$CONF" "$T/installed"
check "no reload" test "$(kills)" = 1
check "launchers kept" test -x "$LP" -a -x "$LS"
check "app kept" test -x "$APP/Contents/MacOS/TouchGlass"
check "says the app stays" out_has "Kept $APP, because gpg-agent.conf still uses it."
check "restores the marked pinentry line" out_has "Replace lines 2 and 3:"
check "with the original" out_has "    pinentry-program $EX"
check "deletes the added scdaemon lines" out_has "line 4: # touchglass: added scdaemon-program"
check "explains why the launchers stay" out_has "stay in place while gpg-agent.conf names them"
check "prints the reload command" out_has "gpgconf --kill gpg-agent"
check "offers --apply" out_has "touchglass uninstall --apply"
# Make the change the way the instructions say.
cp "$T/original" "$CONF"
tg uninstall --remove-app
check "then removes the launchers" test ! -e "$SUPPORT/bin"
check "and the app" test ! -e "$APP"
check "keeps the settings" test -f "$SUPPORT/pinentry.conf"
check "still no reload" test "$(kills)" = 1

begin "manual uninstall after a manual install"
printf '%s\n' "#pinentry-program $EX" "pinentry-program $LP" "scdaemon-program $LS" > "$CONF"
tg install --from "$app"
tg uninstall
check "deletes the pinentry line" out_has "line 2: pinentry-program $LP"
check "deletes the scdaemon line" out_has "line 3: scdaemon-program $LS"
check "points at the commented-out line" out_has "line 1: #pinentry-program $EX"
tg uninstall --dry-run
check "dry run shows the same steps" out_has "line 2: pinentry-program $LP"

begin "uninstall --check, for brew uninstall --zap"
check "passes before any install" tg uninstall --check
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg install --apply --from "$app"
if "$tool" uninstall --check > "$T/out" 2> "$T/err"; then fail "passed while gpg-agent.conf names the launchers"; fi
check "names the lines" grep -qF "line 2: pinentry-program $LP" "$T/err"
check "says how to revert" grep -qF "touchglass uninstall --apply" "$T/err"
# Reverted by hand, but the launchers are still there: another GnuPG home might use them.
cp "$CONF" "$T/installed"
printf '%s\n' "pinentry-program $EX" > "$CONF"
if "$tool" uninstall --check > "$T/out" 2> "$T/err"; then fail "passed while the launchers exist"; fi
check "explains the launchers" grep -qF "launchers in $SUPPORT/bin are still installed" "$T/err"
cp "$T/installed" "$CONF"
tg uninstall --apply
check "passes after uninstall --apply" tg uninstall --check
# Helpers named directly count too: zap deletes the app they live in.
printf '%s\n' "pinentry-program $APP/Contents/MacOS/touchglass-pinentry" > "$CONF"
if "$tool" uninstall --check > "$T/out" 2>&1; then fail "passed while gpg-agent.conf names a helper directly"; fi

begin "the CLI copy in the support directory uninstalls after the app is gone"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
"$SUPPORT/bin/touchglass" status > "$T/out" 2>&1
check "copy finds the app through the launchers" out_has "App:               $APP (version 0.1.0)"
rm -rf "$APP"
"$SUPPORT/bin/touchglass" status > "$T/out" 2>&1
check "copy reports the fallbacks" out_has "running the fallbacks, because $APP is missing"
"$SUPPORT/bin/touchglass" uninstall --apply > "$T/out" 2>&1 || fail "uninstall from the copy failed"
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"
check "launchers and copy removed" test ! -e "$SUPPORT/bin"

begin "an app in a Homebrew keg: the launchers use the stable opt path"
keg="$T/brew/Cellar/touchglass/1.0"
mkdir -p "$keg" "$T/brew/opt" "$T/brew/bin"
ditto "$app" "$keg/TouchGlass.app"
mkdir -p "$keg/TouchGlass.app/Contents/Resources"
cp "$tool" "$keg/TouchGlass.app/Contents/Resources/touchglass"
ln -s ../Cellar/touchglass/1.0 "$T/brew/opt/touchglass"
ln -s ../Cellar/touchglass/1.0/TouchGlass.app/Contents/Resources/touchglass "$T/brew/bin/touchglass"
"$T/brew/bin/touchglass" install > "$T/out" 2>&1 || fail "install from the keg failed"
check "launcher records the opt path" grep -qx "app='$(cd "$T" && pwd -P)/brew/opt/touchglass/TouchGlass.app'" "$LP"
check "no copy to ~/Applications" test ! -e "$APP"

begin "a failing gpgconf --kill is reported"
printf '%s\n' "pinentry-program $EX" > "$CONF"
touch "$T/gpgconf-kill-fails"
if "$tool" install --apply --from "$app" > "$T/out" 2>&1; then fail "install exited 0 although gpgconf --kill failed"; fi
check "warns that the conf is written" out_has "gpg-agent.conf is written, but 'gpgconf --kill gpg-agent' failed"
check "conf written" grep -q touchglass-pinentry "$CONF"
if "$tool" uninstall --apply > "$T/out" 2>&1; then fail "uninstall exited 0 although gpgconf --kill failed"; fi
check "uninstall warns too" out_has "'gpgconf --kill gpg-agent' failed"
check "launchers kept while gpg-agent may run them" test -x "$LP"

begin "copy inside the app, run through a symlink: uses that app in place"
mkdir -p "$app/Contents/Resources" "$T/prefix/bin"
cp "$tool" "$app/Contents/Resources/touchglass"
ln -s ../../src/TouchGlass.app/Contents/Resources/touchglass "$T/prefix/bin/touchglass"
bundled="$(cd "$app" && pwd -P)"
btg() { "$T/prefix/bin/touchglass" "$@" > "$T/out" 2>&1 || { echo "    touchglass $* failed:"; sed 's/^/      /' "$T/out"; return 1; }; }
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
btg install --apply --dry-run
check "dry run copies nothing" sh -c "! grep -q 'Would copy' '$T/out'"
check "dry run writes nothing" cmp -s "$CONF" "$T/original"
btg install --apply
check "conf names the launchers" grep -qx "pinentry-program $LP" "$CONF"
check "launchers run the bundle" grep -qx "app='$bundled'" "$LP"
check "scdaemon launcher too" grep -qx "app='$bundled'" "$LS"
check "the CLI is copied next to the launchers" cmp -s "$SUPPORT/bin/touchglass" "$tool"
check "no copy to ~/Applications" test ! -e "$APP"
check "no scdaemon restart without a copy" test "$(scd_kills)" = 0
btg status
check "status finds the bundle" out_has "App:               $bundled (version 0.1.0)"
btg uninstall --apply
check "round trip is byte-identical" cmp -s "$CONF" "$T/original"
btg status
check "status without conf lines falls back to the bundle" out_has "App:               $bundled (version 0.1.0)"
btg install --apply --app-dir "$HOME/Applications"
check "--app-dir copies the bundle" test -x "$APP/Contents/MacOS/touchglass-pinentry"
check "launchers point at the copy" grep -qx "app='$APP'" "$LP"

begin "the pinentry launcher falls back to pinentry when pinentry-mac is gone too"
tg install --from "$app"
rm -rf "$APP"
mkdir -p "$T/no-pinentry-here"
rm "$EX" "$T/bin/pinentry-mac"
echo_stub "$T/no-pinentry-here/pinentry" plain-pinentry
printf '' | "$LP" --ttyname /dev/null > "$T/run"
check "runs pinentry" grep -q '^plain-pinentry pid=[0-9]* args=--ttyname /dev/null$' "$T/run"
echo_stub "$T/no-pinentry-here/pinentry-mac" default-pinentry-mac
printf '' | "$LP" > "$T/run"
check "pinentry-mac comes first" grep -q '^default-pinentry-mac ' "$T/run"
rm "$T/no-pinentry-here/pinentry-mac"
tg status
check "status names the fallback in use" out_has "Fallback pinentry: $T/no-pinentry-here/pinentry, because $T/bin/pinentry-mac is missing"
rm "$T/no-pinentry-here/pinentry"
tg status
check "status warns without any fallback" out_has "Fallback pinentry: none executable"

begin "install skips a configured pinentry that doesn't exist"
printf '%s\n' "pinentry-program $T/gone/pinentry-mac" > "$CONF"
tg install --apply --from "$app"
check "warns" out_has "$T/gone/pinentry-mac, which is not executable"
check "fallback is pinentry-mac instead" grep -qx "fallback-pinentry = $T/bin/pinentry-mac" "$SUPPORT/pinentry.conf"

begin "install --apply with a dangling gpg-agent.conf symlink"
ln -s "$T/missing/gpg-agent.conf" "$CONF"
if "$tool" install --apply --from "$app" > "$T/out" 2>&1; then fail "install exited 0"; fi
check "names the symlink and its target" out_has "is a symlink to $T/missing/gpg-agent.conf, which doesn't exist"
check "wrote nothing" test ! -e "$SUPPORT" -a ! -e "$APP"

begin "uninstall --remove-app refuses an app in a Homebrew keg"
keg="$T/brew/Cellar/touchglass/1.0"
mkdir -p "$keg" "$T/brew/opt"
ditto "$app" "$keg/TouchGlass.app"
ln -s ../Cellar/touchglass/1.0 "$T/brew/opt/touchglass"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$T/brew/opt/touchglass/TouchGlass.app" --app-dir "$T/brew/opt/touchglass"
if "$tool" uninstall --apply --remove-app > "$T/out" 2>&1; then fail "uninstall --remove-app exited 0"; fi
check "points at brew uninstall" out_has "brew uninstall touchglass"
check "keg app intact" test -x "$keg/TouchGlass.app/Contents/MacOS/TouchGlass"
check "conf not changed either" grep -qx "pinentry-program $LP" "$CONF"
tg uninstall --apply
check "uninstall without --remove-app works" cmp -s "$CONF" "$T/original"

begin "uninstall --apply without gpgconf keeps the launchers"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
rm "$T/bin/gpgconf"
tg uninstall --apply --dry-run
check "dry run says they stay" out_has "Would keep the launchers"
tg uninstall --apply
check "conf restored" cmp -s "$CONF" "$T/original"
check "launchers kept" test -x "$LP" -a -x "$LS"
check "says why" out_has "without gpgconf uninstall couldn't stop gpg-agent"
# After the agent stopped, uninstall removes them.
tg uninstall
check "then removes them" test ! -e "$SUPPORT/bin"

begin "manual uninstall keeps the launchers while an older gpg-agent runs"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
cp "$T/original" "$CONF"
# This gpg-agent started 2 hours ago, before gpg-agent.conf changed.
echo "02:00:00" > "$T/agent-etime"
tg uninstall --dry-run
check "dry run says they stay" out_has "Would keep the launchers"
tg uninstall
check "launchers kept" test -x "$LP" -a -x "$LS"
check "says to stop gpg-agent" out_has "gpgconf --kill gpg-agent"
# A gpg-agent that started after the change read the restored file.
touch -t 202001010000 "$CONF"
echo "00:05" > "$T/agent-etime"
tg uninstall
check "then removes them" test ! -e "$SUPPORT/bin"
check "no kill by uninstall" test "$(kills)" = 1

begin "uninstall keeps the launchers while another GnuPG home names them"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
mkdir -m 700 "$T/gnupg2"
printf '%s\n' "pinentry-program $EX" > "$T/gnupg2/gpg-agent.conf"
GNUPGHOME="$T/gnupg2" "$tool" install --apply --from "$app" > "$T/out" 2>&1 || fail "second install failed"
GNUPGHOME="$T/gnupg2" "$tool" uninstall --apply > "$T/out" 2>&1 || fail "second uninstall failed"
check "second home restored" cmp -s "$T/gnupg2/gpg-agent.conf" "$T/original"
check "launchers kept" test -x "$LP" -a -x "$LS"
check "names the other file" out_has "because $CONF still names them"
tg uninstall --apply
check "first home restored" cmp -s "$CONF" "$T/original"
check "then removed" test ! -e "$SUPPORT/bin"

begin "uninstall --apply keeps the launchers while another home's older gpg-agent runs"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
mkdir -m 700 "$T/gnupg2"
printf '%s\n' "pinentry-program $EX" > "$T/gnupg2/gpg-agent.conf"
GNUPGHOME="$T/gnupg2" "$tool" install --apply --from "$app" > "$T/out" 2>&1 || fail "second install failed"
# The second home's file is restored by hand, but its gpg-agent, started 2 hours ago, still runs.
cp "$T/original" "$T/gnupg2/gpg-agent.conf"
echo "02:00:00" > "$T/agent-etime"
tg uninstall --apply
check "first home restored" cmp -s "$CONF" "$T/original"
check "launchers kept" test -x "$LP" -a -x "$LS"
check "says another gpg-agent runs" out_has "another gpg-agent that started before"
# After that gpg-agent stopped, uninstall removes them.
rm "$T/agent-etime"
tg uninstall
check "then removes them" test ! -e "$SUPPORT/bin"

begin "GNU stat first on PATH"
# GNU coreutils' stat reads -f as "file system status" and the format as a file name. This stub
# behaves like that for -f and fails the tests if the script calls stat through PATH at all.
cat > "$T/bin/stat" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/stat.log"
for arg in "\$@"; do
    case "\$arg" in -*) ;; *) printf '  File: "%s"\n    ID: 1000004 Namelen: 255 Type: apfs\n' "\$arg" ;; esac
done
exit 1
EOF
chmod +x "$T/bin/stat"
printf '%s\n' "pinentry-program $EX" > "$CONF"
chmod 640 "$CONF"
cp "$CONF" "$T/original"
tg install --apply --from "$app"
check "install --apply writes the conf" grep -qx "pinentry-program $LP" "$CONF"
check "mode kept" test "$(/usr/bin/stat -f %Lp "$CONF")" = 640
# A manual uninstall while a gpg-agent from before the change runs keeps the launchers.
cp "$T/original" "$CONF"
echo "02:00:00" > "$T/agent-etime"
tg uninstall
check "launchers kept" test -x "$LP" -a -x "$LS"
rm "$T/agent-etime"
tg install --apply --from "$app"
tg uninstall --apply
check "uninstall --apply restores the conf" cmp -s "$CONF" "$T/original"
check "the stub was never called" test ! -e "$T/stat.log"

begin "status reports the scdaemon proxy"
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg install --apply --from "$app"
tg status
check "not running" out_has "scdaemon proxy:    not running; gpg-agent starts it"
touch "$T/running-scdaemon"
tg status
check "real scdaemon without the proxy" out_has "scdaemon runs without it"
touch "$T/running-touchglass-scdaemon"
tg status
check "running" out_has "scdaemon proxy:    running"

# Turns the launchers into ones of format 0, as installs wrote them before the format stamp.
make_format_0() {
    for launcher in "$LP" "$LS"; do
        sed -e '/^# touchglass-launcher /d' -e 's/TOUCHGLASS_LAUNCHER=1; export TOUCHGLASS_LAUNCHER; //' "$launcher" > "$T/stale"
        cat "$T/stale" > "$launcher"
    done
}
inode() { ls -i "$1" | awk '{ print $1 }'; }

begin "refresh-launchers rewrites stale launchers as install writes them"
printf '%s\n' "pinentry-program $EX" > "$CONF"
tg install --apply --from "$app"
mkdir -p "$T/installed"
cp -p "$LP" "$LS" "$SUPPORT/bin/touchglass" "$SUPPORT/pinentry.conf" "$SUPPORT/scdaemon-program" "$CONF" "$T/installed/"
make_format_0
check "stale launchers lack the stamp" sh -c "! grep -q '^# touchglass-launcher' '$LP'"
sed 's/^cli_version=.*/cli_version=0.0.1/' "$tool" > "$SUPPORT/bin/touchglass"
reloads="$(kills)"
tg refresh-launchers
check "pinentry launcher as install wrote it" cmp -s "$LP" "$T/installed/touchglass-pinentry"
check "scdaemon launcher as install wrote it" cmp -s "$LS" "$T/installed/touchglass-scdaemon"
check "launchers stay executable" test "$(/usr/bin/stat -f %Lp "$LP")" = 755 -a "$(/usr/bin/stat -f %Lp "$LS")" = 755
check "CLI copy replaced" cmp -s "$SUPPORT/bin/touchglass" "$tool"
check "gpg-agent.conf untouched" cmp -s "$CONF" "$T/installed/gpg-agent.conf"
check "pinentry.conf untouched" cmp -s "$SUPPORT/pinentry.conf" "$T/installed/pinentry.conf"
check "scdaemon path untouched" cmp -s "$SUPPORT/scdaemon-program" "$T/installed/scdaemon-program"
check "no backup" test "$(backups)" = 1
check "gpg-agent left running" test "$(kills)" = "$reloads"
check "says what it rewrote" out_has "Rewrote the launchers for $APP"
check "no staged files left" test -z "$(ls -A "$SUPPORT/bin" | grep '^\.')"
before="$(inode "$LP")"
tg refresh-launchers
check "second run reports current launchers" out_has "are current"
check "second run writes nothing" test "$(inode "$LP")" = "$before"

begin "refresh-launchers keeps the app that the launchers run"
tg install --from "$app"
cp "$LP" "$T/expected"
mkdir -p "$app/Contents/Resources"
cp "$tool" "$app/Contents/Resources/touchglass"
make_format_0
"$app/Contents/Resources/touchglass" refresh-launchers > "$T/out" 2>&1 || fail "refresh from the bundle failed"
check "launchers still run the installed app" cmp -s "$LP" "$T/expected"

begin "refresh-launchers without an install does nothing"
printf '%s\n' "pinentry-program $EX" > "$CONF"
cp "$CONF" "$T/original"
tg refresh-launchers
check "says there is nothing to refresh" out_has "nothing to refresh"
check "no support files" test ! -e "$SUPPORT"
check "gpg-agent.conf untouched" cmp -s "$CONF" "$T/original"

begin "refresh-launchers never downgrades"
tg install --from "$app"
sed 's/^# touchglass-launcher 1$/# touchglass-launcher 2/' "$LP" > "$T/later"
cat "$T/later" > "$LP"
sed -e '/^# touchglass-launcher /d' "$LS" > "$T/stale-scd"
cat "$T/stale-scd" > "$LS"
if "$tool" refresh-launchers > "$T/out" 2>&1; then fail "refresh over a later launcher format exited 0"; fi
check "explains the refusal" out_has "a later TouchGlass wrote"
check "later launcher kept" cmp -s "$LP" "$T/later"
check "other launcher left alone too" cmp -s "$LS" "$T/stale-scd"
# A copy of the command from a later release stays; one from an earlier release is replaced.
tg install --from "$app"
mkdir -p "$T/release"
sed 's/^cli_version=.*/cli_version=1.2.0/' "$tool" > "$T/release/touchglass"
chmod +x "$T/release/touchglass"
sed 's/^cli_version=.*/cli_version=1.10.0/' "$tool" > "$SUPPORT/bin/touchglass"
cp "$SUPPORT/bin/touchglass" "$T/later-cli"
"$T/release/touchglass" refresh-launchers > "$T/out" 2>&1 || fail "refresh with a later CLI copy failed"
check "later CLI copy kept" cmp -s "$SUPPORT/bin/touchglass" "$T/later-cli"
check "says why" out_has "from the later release 1.10.0"
sed 's/^cli_version=.*/cli_version=1.1.9/' "$tool" > "$SUPPORT/bin/touchglass"
"$T/release/touchglass" refresh-launchers > "$T/out" 2>&1 || fail "refresh with an earlier CLI copy failed"
check "earlier CLI copy replaced" cmp -s "$SUPPORT/bin/touchglass" "$T/release/touchglass"

begin "two refreshes at once"
tg install --from "$app"
cp "$LP" "$LS" "$T/"
make_format_0
"$tool" refresh-launchers > "$T/out1" 2>&1 & first=$!
"$tool" refresh-launchers > "$T/out2" 2>&1 & second=$!
wait "$first" || fail "first refresh failed"
wait "$second" || fail "second refresh failed"
check "pinentry launcher whole" cmp -s "$LP" "$T/touchglass-pinentry"
check "scdaemon launcher whole" cmp -s "$LS" "$T/touchglass-scdaemon"
check "no staged files left" test -z "$(ls -A "$SUPPORT/bin" | grep '^\.')"

printf '\n%d sandboxes, %d failures\n' "$count" "$failures"
[ "$failures" = 0 ]
