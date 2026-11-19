# TouchGlass

TouchGlass is a macOS panel for YubiKey operations through gpg-agent. When a signature, SSH login or decryption needs the card, one floating Liquid Glass panel asks for the PIN, then shows "Touch your YubiKey" with a countdown to the card's touch timeout, then confirms and closes itself.

Run without arguments, the app is the host: it listens on a Unix socket for `touchglass-pinentry` and `touchglass-scdaemon` and shows the panel for their prompts and card operations. To connect the helpers to gpg-agent, see [Install](#install).

## Requirements

- macOS 26 or later.
- Swift 6 with the macOS 26 SDK or later. The Command Line Tools are enough; Xcode is not required.

## Build

```sh
scripts/build-app.sh
```

The script builds `build/TouchGlass.app` with Swift Package Manager and signs it ad hoc. The app has no Dock icon. Pass `debug` to build the debug configuration.

To run the unit tests:

```sh
scripts/test.sh
```

The script passes the Swift Testing macro plugin path to `swift test`, because with only the Command Line Tools installed the build sometimes fails to find that plugin.

## Install

`scripts/touchglass install` connects TouchGlass to gpg-agent. Preview the change first; `--dry-run` prints the edit to `gpg-agent.conf` as a diff and writes nothing:

```sh
scripts/touchglass install --dry-run
scripts/touchglass install
```

Install does the following:

1. Builds `build/TouchGlass.app` if it is missing or older than the sources, and copies it to `~/Applications`. To install somewhere else, pass `--app-dir <directory>`; to install a bundle you built yourself, pass `--from <path to TouchGlass.app>`.
2. Writes the path of the real scdaemon to `~/Library/Application Support/TouchGlass/scdaemon-program`. The path comes from the `scdaemon-program` line that `gpg-agent.conf` already has, or else from `gpgconf --list-components`. For Homebrew, install prefers a stable path such as `/opt/homebrew/opt/gnupg/libexec/scdaemon` over the versioned `Cellar` path, which a GnuPG upgrade removes.
3. If `~/Library/Application Support/TouchGlass/pinentry.conf` doesn't exist, writes it with `fallback-pinentry` set to the pinentry that `gpg-agent.conf` named before, else `pinentry-mac`, else the pinentry that `gpgconf --list-components` reports. `touchglass-pinentry` hands prompts to that pinentry when the TouchGlass host isn't reachable. If install finds no pinentry at all, it warns and leaves the setting out. On a later install, it replaces a `fallback-pinentry` that no longer exists and keeps one that works.
4. Backs up `gpg-agent.conf` to `gpg-agent.conf.touchglass-backup-<timestamp>` next to it.
5. Points `pinentry-program` and `scdaemon-program` in `gpg-agent.conf` at the helpers in the app bundle. It comments out the effective line with a `# touchglass: ` prefix and adds the TouchGlass line after it. If an option isn't set, it adds a `# touchglass: added <option>` marker and the TouchGlass line at the top of the file. It changes no other line.
6. Stops gpg-agent with `gpgconf --kill gpg-agent`, so it reads the new settings on next use. gpg-agent forgets its cached PINs and passphrases, so the next card operation asks for the PIN again.

Install uses `GNUPGHOME` if it is set, and `~/.gnupg` otherwise. If the GnuPG home doesn't exist, install creates it with mode 700.

Running install again, for example after you pulled changes, leaves `gpg-agent.conf` as it is and adds no second backup or marker. It replaces the installed app, and then:

- Quits the running host with `pkill -x TouchGlass`. The helpers start the new host on the next prompt or card operation.
- Stops scdaemon with `gpgconf --kill scdaemon`. The running `touchglass-scdaemon` lives as long as scdaemon does, often for days, so without this the previous version keeps handling card operations. gpg-agent starts scdaemon again on the next card operation, and the card asks for the PIN again.

Install copies the new app next to the old one and then swaps them, so a failed copy leaves the installed app whole. `--dry-run` lists these steps too.

To see what gpg-agent uses, whether the host is running, the installed app version and the backups:

```sh
scripts/touchglass status
```

## Uninstall

```sh
scripts/touchglass uninstall --dry-run
scripts/touchglass uninstall
```

Uninstall restores the original `pinentry-program` and `scdaemon-program` lines from the `# touchglass: ` markers, so the file matches what it was before install, and stops gpg-agent. If the markers are missing, it takes the original lines from the newest backup. It works when the app was moved or deleted. To also delete the installed app, pass `--remove-app`.

Uninstall leaves these behind, for you to delete if you don't reinstall:

- The `gpg-agent.conf.touchglass-backup-<timestamp>` files next to `gpg-agent.conf`.
- `~/Library/Application Support/TouchGlass`, which holds `pinentry.conf`, `scdaemon-program`, `host.conf` if you wrote one, and the host's socket. A later install reuses `pinentry.conf`.
- The installed app, unless you pass `--remove-app`.
- A running host. Quit it with `pkill -x TouchGlass`.

To test the installer:

```sh
scripts/test-installer.sh
```

The tests run each case with a temporary `HOME` and `GNUPGHOME` and stub `gpgconf`, `pgrep` and `pkill` commands, so they don't touch your GnuPG setup, stop your gpg-agent or quit your TouchGlass host.

## Run the demo

The demo shows scripted panel states with simulated card replies:

```sh
build/TouchGlass.app/Contents/MacOS/TouchGlass --demo sign
```

Scenarios: `sign`, `touch`, `timeout`, `wrong-pin`, `ssh`, `decrypt`, `blocked`, `passphrase`, `insert-card`, `message`, `removed`, `error`, `client`, and `all`, which runs every scenario in sequence. `--help` describes each one.

In the demo, any text in the PIN field continues. To simulate the touch, click **Simulate touch** in the demo controls window, or press Space while that window is focused. Without a touch, the demo touches after 4 seconds.

| Option | Effect |
| --- | --- |
| `--touch-after <seconds>` | Simulates the touch after this many seconds. |
| `--auto-submit <seconds>` | Submits PIN, passphrase and confirm prompts without typing. |
| `--slow <factor>` | Slows the panel animations down by this factor, to review them. |
| `--no-controls` | Hides the demo controls window. |
| `--focus-report` | Prints whether the PIN panel took key focus. |
| `--appearance <look>` | Uses the `readable` (default) or `smoked` look, as the `appearance` setting does. |
| `--client <label>` | Shows this label for what asked, instead of each scenario's sample label. |
| `--no-client` | Hides the client line, like `show-client = no`. |

The `client` scenario shows a long label that arrives after the PIN prompt opens and truncates in the middle.

The demo never reads, logs or prints what you type in the PIN field.

## Settings

The host reads `~/Library/Application Support/TouchGlass/host.conf` when it starts, one `key = value` per line, with `#` for comments:

| Key | Values | Effect |
| --- | --- | --- |
| `appearance` | `readable` (default), `smoked` | Regular glass with standard label colours in light mode, or smoked clear glass with HDR white text. |
| `show-client` | `yes` (default), `no` | Shows what asked for the card operation under the detail line, such as `git commit · touchglass` or `ssh build-box`. |
| `touch-timeout` | Seconds, 1 to 600 | Sets the length of the touch countdown. Without it, the host uses the timeout that `touchglass-scdaemon` reports, 15 seconds. Set it only if your card waits for a different time. The reminder sounds and the urgent phase keep their proportions: at a third and two thirds of the countdown. If the value is shorter than the card's own timeout, the countdown reaches 0 and the panel stays until the card answers. |

The demo takes `appearance` as `--appearance`, and `show-client = no` as `--no-client`.

After you change `host.conf`, quit the host so that it reads the file again:

```sh
pkill -x TouchGlass
```

The helpers start the host again on the next prompt or card operation. While the host isn't running and can't be started, `touchglass-pinentry` hands prompts to the `fallback-pinentry`, and card operations work without the touch panel.

### Sounds

The panel plays the system alert sounds Tink, Ping and Basso, at the alert volume. Two user defaults of the app turn them off; both default to on:

```sh
# All panel sounds.
defaults write io.ambroos.touchglass soundsEnabled -bool false
# Only the reminders during the touch countdown.
defaults write io.ambroos.touchglass reminderSoundsEnabled -bool false
```

The host reads them each time it plays a sound, so no restart is needed.

### Pinentry settings

`touchglass-pinentry` reads `~/Library/Application Support/TouchGlass/pinentry.conf`, in the same format, each time gpg-agent starts it:

| Key | Default | Effect |
| --- | --- | --- |
| `fallback-pinentry` | The first of `/opt/homebrew/bin/pinentry-mac` and `/usr/local/bin/pinentry-mac` that exists | The pinentry that takes over a prompt when the host isn't reachable or stops answering. |
| `host-app` | The `TouchGlass.app` that contains the pinentry | The app to start when the host isn't running: a bundle path, an app name, or `none` to never start it. |
| `connect-timeout-ms` | 300 | How long a connection to the host socket may take. |
| `launch-timeout-ms` | 2000 | How long to wait for a host that the pinentry started to accept connections. |
| `ping-interval-ms` | 1000 | How often the pinentry checks that the host still answers while a prompt shows. |
| `host-stall-ms` | 3000 | How long the host may go without answering before the pinentry hands the prompt to the fallback. |
| `log-file` | None | A file for diagnostic lines: message types and Assuan keywords, never a PIN or passphrase. |

### What asked

gpg-agent doesn't tell scdaemon or the pinentry which command needs the card, so the host infers it, best effort. For a PIN prompt, it uses the client PID that gpg-agent passes to the pinentry. For a touch without a PIN prompt, it lists gpg-agent's connected clients by matching the agent's Unix sockets with the sockets of your other processes: an ssh client on the agent's ssh socket for an SSH login, any other client for a signature or decryption. From that process it walks up a few parents and reads their arguments and working directory:

- Under git, the label is the git subcommand and the repository's directory name, such as `git commit · touchglass`. `git push`, `git pull` and `git fetch` add the remote name, or only the host when the command names a URL. The repository name comes from the directory that git runs in, which is the top level of the working tree or worktree; TouchGlass reads no files in the repository.
- An ssh client outside git shows its destination host.
- Anything else shows its executable name, such as `gpg`.

The panel opens without waiting for the label, which fills in when the lookup finishes. The lookup gives up after about 50 ms. If several clients could be the one, and they don't give the same label, the panel shows none.

## Layout

- `TouchGlassCore`: panel states, copy, touch timing and a pure state machine (`PanelMachine`) that turns events into effects. It depends on Foundation and Observation only.
- `TouchGlassPanel`: the SwiftUI views and the AppKit panel window. `PanelController` performs the state machine's effects.
- `TouchGlassHost`: `HostCoordinator`, which merges proxy events and pinentry prompts into panel events and replies, and `HostServer`, which accepts helper connections.
- `TouchGlassIPC`: the messages and socket transport shared with the helpers.
- `TouchGlass`: the app: the host, plus the demo mode.

## License

Apache License 2.0. See [LICENSE](LICENSE).
