# touchglass-scdaemon

`touchglass-scdaemon` sits between gpg-agent and scdaemon and tells the TouchGlass host when a card operation starts, needs a PIN, waits for a touch, and ends. gpg-agent runs it as its `scdaemon-program`. It never changes what gpg-agent and scdaemon say to each other, with one exception described in [Socket relay](#socket-relay).

## How it works

gpg-agent starts `touchglass-scdaemon --multi-server` with a pipe on stdin and stdout. The proxy starts the real scdaemon with the same arguments and environment, then forwards bytes in both directions on one thread per direction, using blocking `read` and `write`. A line tap scans a copy of the stream, recognizes Assuan lines and passes them to an operation detector on its own queue. The detector sends events to the host socket from a separate writer thread through a queue of 64 events. When the host isn't running at an `op_start`, the writer starts the TouchGlass app, at most once every 10 seconds, and waits up to 2 seconds for it to accept connections, so the touch wait that follows reaches it. When the host is still absent, or slow or stopped, events are dropped; forwarding never waits on the detector or the host.

The proxy exits when scdaemon exits, with the same exit status, or by the same signal. When gpg-agent closes the pipe, the proxy closes scdaemon's stdin and keeps forwarding scdaemon's output until scdaemon exits. `SIGTERM`, `SIGINT` and `SIGHUP` are forwarded to scdaemon. `SIGUSR1` and `SIGUSR2` are ignored: scdaemon sends its card event signal to the peer of a socket session, which is the proxy for a relayed session, and the default action would end the proxy.

The proxy's parent is the gpg-agent that started it. Each `op_start` carries that agent's PID as `agent_pid`, so the host looks for the client that asked for the operation among that agent's connections only.

### Socket relay

gpg-agent uses the pipe for one session at a time. Sessions that overlap it, such as an SSH login during a commit signature, connect to the socket that scdaemon names in its reply to `GETINFO socket_name`. To see those sessions, the proxy replaces that path with its own socket, `<per-user temporary directory>/touchglass/scd.<pid>.sock`, and relays each connection to scdaemon's socket with the same tap. If the proxy cannot create its socket, it leaves the reply alone and overlapping sessions work unobserved. An empty reply is never changed.

### What the detector reports

| Event | When |
| --- | --- |
| `op_start` | `PKSIGN`, `PKAUTH` or `PKDECRYPT` reaches scdaemon. The slot and card serial come from the `S KEYINFO` line the agent requests before each operation. `PKSIGN` with the slot 3 key reports `auth`, because scdaemon runs it as an authentication. `agent_pid` is the proxy's parent, the gpg-agent; the field is optional, so hosts and proxies of different versions still understand each other. |
| `pin_needed` | scdaemon sends `INQUIRE NEEDPIN`. |
| `pin_sent` | The agent answers that inquiry with `END`. |
| `touch_wait` | An operation is outstanding, no inquiry is open, and 400 ms passed since the operation command, the last inquiry answer or `S PINCACHE_PUT`. The card sends nothing while it waits for a touch, so this delay is the only signal. `at` is the start of that delay. A `POPUPPINPADPROMPT --ack` inquiry reports it at once. |
| `op_end` | scdaemon answers `OK` or `ERR`. `ERR` codes map to `bad_pin`, `timeout`, `cancelled` or `error`; `code` carries the raw value. |

Each connection has an ID of the form `<proxy pid>:p` for the pipe and `<proxy pid>:s<n>` for relayed socket sessions.

The tap never buffers the payload of a `D` line. PINs, PIN cache values, signatures and decrypted data are skipped byte by byte and never reach the detector, the host or a log. The proxy writes nothing to a log.

## Configuration

The proxy finds the real scdaemon in this order:

1. The `TOUCHGLASS_SCDAEMON_PROGRAM` environment variable.
2. The first line of `~/Library/Application Support/TouchGlass/scdaemon-program`, which the installer writes from `gpgconf --list-components`.
3. `/opt/homebrew/libexec/scdaemon`, `/usr/local/libexec/scdaemon`, `/usr/local/MacGPG2/libexec/scdaemon`, `/opt/local/libexec/scdaemon`.

The proxy starts the app bundle it lives in, `TouchGlass.app/Contents/MacOS/touchglass-scdaemon`, with `open -g`. Outside a bundle, it opens the app named `TouchGlass`. The `TOUCHGLASS_HOST_APP` environment variable overrides this with a bundle path or an app name; `none` never starts the host.

Other environment variables, for tests: `TOUCHGLASS_SOCKET` (host socket), `TOUCHGLASS_RUNTIME_DIR` (directory for the relay socket) and `TOUCHGLASS_TOUCH_DELAY_MS` (touch detection delay).

## Test tools

None of these touch a card, gpg-agent or `~/.gnupg`.

- `fake-scdaemon` plays an OpenPGP card from a JSON config named by `FAKE_SCD_CONFIG`: keygrips and slots, PIN, PIN cache inquiries, touch delay and timeout, cached touch window, and exit behaviour. It records every byte per connection for transparency checks. See the comment at the top of `Sources/fake-scdaemon/main.swift`.
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
