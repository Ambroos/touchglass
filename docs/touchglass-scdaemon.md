# touchglass-scdaemon

`touchglass-scdaemon` sits between gpg-agent and scdaemon and tells the TouchGlass host when a card operation starts, needs a PIN, waits for a touch, and ends. gpg-agent runs it as its `scdaemon-program`, through the launcher `~/Library/Application Support/TouchGlass/bin/touchglass-scdaemon`, which replaces itself with the proxy using `exec`; while `TouchGlass.app` is missing, the launcher runs the real scdaemon instead. The proxy never changes what gpg-agent and scdaemon say to each other, with one exception described in [Socket relay](#socket-relay).

## How it works

gpg-agent starts `touchglass-scdaemon --multi-server` with a pipe on stdin and stdout. The proxy starts the real scdaemon with the same arguments and environment, then forwards bytes in both directions on one thread per direction, using blocking `read` and `write`. A line tap scans a copy of the stream, recognizes Assuan lines and passes them to an operation detector on its own queue. The detector sends events to the host socket from a separate writer thread through a queue of 64 events. When the host isn't running at an `op_start` or a `touch_wait`, the writer starts the TouchGlass app, at most once every 10 seconds, and waits up to 2 seconds for it to accept connections, so that event and the ones that follow reach it. When the host is still absent, or slow or stopped, events are dropped; forwarding never waits on the detector or the host.

The proxy exits when scdaemon exits, with the same exit status, or by the same signal. When gpg-agent closes the pipe, the proxy closes scdaemon's stdin and keeps forwarding scdaemon's output until scdaemon exits. `SIGTERM`, `SIGINT` and `SIGHUP` are forwarded to scdaemon. `SIGUSR1` and `SIGUSR2` are ignored: scdaemon sends its card event signal to the peer of a socket session, which is the proxy for a relayed session, and the default action would end the proxy. scdaemon itself starts with all five signals at their default actions and `SIGPIPE` as gpg-agent left it, the same as without the proxy.

The proxy's parent is the gpg-agent that started it. Each `op_start` carries that agent's PID as `agent_pid`, so the host looks for the client that asked for the operation among that agent's connections only. The proxy's `hello` carries that agent's GnuPG home, from the `--homedir` argument that gpg-agent passes for a home other than its default, else `GNUPGHOME`, and the `bin` directory next to the real scdaemon's `libexec` directory. The host uses them to ask gpg-agent for a card's touch policy.

### Socket relay

gpg-agent uses the pipe for one session at a time. Sessions that overlap it, such as an SSH login during a commit signature, connect to the socket that scdaemon names in its reply to `GETINFO socket_name`. To see those sessions, the proxy replaces that path with its own socket, `<per-user temporary directory>/touchglass/scd.<pid>.sock`, and relays each connection to scdaemon's socket with the same tap. If the proxy cannot create its socket, it leaves the reply alone and overlapping sessions work unobserved. An empty reply is never changed.

### What the detector reports

| Event | When |
| --- | --- |
| `op_start` | `PKSIGN`, `PKAUTH` or `PKDECRYPT` reaches scdaemon. The slot and card serial come from the `S KEYINFO` line the agent requests before each operation. `PKSIGN` with the slot 3 key reports `auth`, because scdaemon runs it as an authentication. `agent_pid` is the proxy's parent, the gpg-agent; the field is optional, so hosts and proxies of different versions still understand each other. |
| `pin_needed` | scdaemon sends `INQUIRE NEEDPIN`. |
| `pin_sent` | The agent answers that inquiry with `END`. |
| `touch_wait` | An operation is outstanding, no inquiry is open, and 400 ms passed since the operation command, the last inquiry answer or `S PINCACHE_PUT`. The card sends nothing while it waits for a touch, so this delay is the only signal. `at` is the start of that delay. A `POPUPPINPADPROMPT --ack` inquiry reports it at once and sets `pinpad`. |
| `op_end` | scdaemon answers `OK` or `ERR`. `ERR` codes map to `bad_pin`, `timeout`, `cancelled` or `error`; `code` carries the raw value. |
| `touch_policy` | scdaemon sends `S UIF-1`, `S UIF-2` or `S UIF-3`, the touch policy of the signature, decryption or authentication key, after an `S SERIALNO` on the same connection named the card. scdaemon sends these lines for `LEARN`, which gpg-agent sends for `gpg --card-status`, and for `GETATTR UIF`. `uif` is the first byte of the value; see [Touch policies](configuration.md#touch-policies). Without an earlier `S SERIALNO`, the proxy reports nothing, because it can't tell which card the line is about. |

Each connection has an ID of the form `<proxy pid>:p` for the pipe and `<proxy pid>:s<n>` for relayed socket sessions.

The tap never buffers the payload of a `D` line. PINs, PIN cache values, signatures and decrypted data are skipped byte by byte and never reach the detector, the host or a log.

### Touch cache window

A YubiKey with the `cached` touch policy keeps a touch for 15 seconds, restarts that window on every operation that uses it, and lets one touch cover every key on the card. An operation inside the window can still stay silent for longer than 400 ms, for example during a rebase that signs many commits, so the proxy reports a `touch_wait` for an operation that needs no touch.

The host, not the proxy, handles this, because the window belongs to the card: an SSH login on one scdaemon session uses the touch of a signature on another, and only the host sees every proxy and the queue of touch waits. Each successful `op_end` restarts the window of its card serial, unless the key's touch policy is `off`; see [Touch policies](configuration.md#touch-policies). A `touch_wait` whose command started inside the window shows the touch step only 1.5 s after that command. If the operation ends first, the panel shows nothing for it: no touch step and no result. When the panel does show, the countdown still runs from the command's `at`, so it shows the time the card has left. A touch wait queued behind another one counts from the end of the operation before it, which restarted the window. After a PIN prompt, the touch step replaces the verifying state at once, as outside the window.

The window applies only to keys whose touch policy is `cached` or `cached-fixed`, and to keys whose policy the host doesn't know. For a key with the `on` or `fixed` policy, the touch step shows after 400 ms, inside the window too. For a key with the `off` policy, the host shows no inferred touch wait.

### Logging

The proxy writes to the unified log under the subsystem `io.ambroos.touchglass`, category `scdaemon`: when it starts and when scdaemon exits, each operation's start and end with its kind, slot, the last 4 digits of the card serial, result and durations, each inferred touch wait with the time that passed, and the host connection. At debug level it also logs every scdaemon command by keyword, with its result and duration. Log calls take a fixed set of events with typed values, so no line from the Assuan stream reaches the log. See [Read the log](configuration.md#read-the-log).

## Configuration

The proxy finds the real scdaemon in this order:

1. The `TOUCHGLASS_SCDAEMON_PROGRAM` environment variable.
2. The first line of `~/Library/Application Support/TouchGlass/scdaemon-program`, which the installer writes from the `scdaemon-program` line that `gpg-agent.conf` had before TouchGlass, or from `gpgconf --list-components`. The launcher reads the same file.
3. `/opt/homebrew/libexec/scdaemon`, `/usr/local/libexec/scdaemon`, `/usr/local/MacGPG2/libexec/scdaemon`, `/opt/local/libexec/scdaemon`.

The proxy starts the app bundle it lives in, `TouchGlass.app/Contents/MacOS/touchglass-scdaemon`, with `open -g`. It takes the bundle from the path it was started with, without resolving symlinks, so a proxy that the launcher started through Homebrew's `…/opt/touchglass/TouchGlass.app` keeps opening that path after `brew upgrade` deletes the versioned `Cellar` directory. If a host that it started quits, the proxy starts it again at the next `op_start` or `touch_wait`; it waits 10 s between launches only after one that failed. Its first `hello` carries the release from the app's `Info.plist`, read when the proxy starts. A host of an earlier release that receives a later one exits when it has nothing to show, so the next helper starts the installed host. Later hellos from the same proxy carry no release: the next host comes from the same bundle path, so if the proxy outlived a downgrade, reporting again would only make a host of the installed release exit after every operation. Outside a bundle, it opens the app named `TouchGlass`. The `TOUCHGLASS_HOST_APP` environment variable overrides this with a bundle path or an app name; `none` never starts the host.

Other environment variables, for tests: `TOUCHGLASS_SOCKET` (host socket), `TOUCHGLASS_RUNTIME_DIR` (directory for the relay socket) and `TOUCHGLASS_TOUCH_DELAY_MS` (touch detection delay).

## Test tools

None of these touch a card, gpg-agent or `~/.gnupg`.

- `fake-scdaemon` plays an OpenPGP card from a JSON config named by `FAKE_SCD_CONFIG`: keygrips and slots, PIN, PIN cache inquiries, touch delay and timeout, cached touch window and the time a cached operation takes, and exit behaviour. It records every byte per connection for transparency checks. See the comment at the top of `Sources/fake-scdaemon/main.swift`.
- `fake-agent` drives any `scdaemon-program` the way gpg-agent does and prints the replies, with `D` payloads shown only as lengths.
- `fake-host` listens on the host socket and prints each event as a JSON line.

To watch events from a fake card by hand:

```sh
swift build
mkdir -p -m 700 "$TMPDIR/tg"
.build/debug/fake-host --socket "$TMPDIR/tg/host.sock" &
echo '{"keys":{"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA":1},"touch_ms":3000}' > "$TMPDIR/tg/card.json"
TOUCHGLASS_SOCKET="$TMPDIR/tg/host.sock" \
TOUCHGLASS_SCDAEMON_PROGRAM="$PWD/.build/debug/fake-scdaemon" \
FAKE_SCD_CONFIG="$TMPDIR/tg/card.json" \
.build/debug/fake-agent "KEYINFO AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "PKSIGN --hash=sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
```

The tests in `Tests/ScdProxyTests` run the same setup with `swift test --filter ScdProxyTests`.
