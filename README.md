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
3. If `~/Library/Application Support/TouchGlass/pinentry.conf` doesn't exist, writes it with `fallback-pinentry` set to the pinentry that `gpg-agent.conf` named before, or to `pinentry-mac`. `touchglass-pinentry` hands prompts to that pinentry when the TouchGlass host isn't reachable.
4. Backs up `gpg-agent.conf` to `gpg-agent.conf.touchglass-backup-<timestamp>` next to it.
5. Points `pinentry-program` and `scdaemon-program` in `gpg-agent.conf` at the helpers in the app bundle. It comments out the effective line with a `# touchglass: ` prefix and adds the TouchGlass line after it. If an option isn't set, it adds a `# touchglass: added <option>` marker and the TouchGlass line at the top of the file. It changes no other line.
6. Stops gpg-agent with `gpgconf --kill gpg-agent`, so it reads the new settings on next use. gpg-agent forgets its cached PINs and passphrases, so the next card operation asks for the PIN again.

Running install again changes nothing, and adds no second backup or marker. Install uses `GNUPGHOME` if it is set, and `~/.gnupg` otherwise.

To see what gpg-agent uses, whether the host is running, the installed app version and the backups:

```sh
scripts/touchglass status
```

## Uninstall

```sh
scripts/touchglass uninstall --dry-run
scripts/touchglass uninstall
```

Uninstall restores the original `pinentry-program` and `scdaemon-program` lines from the `# touchglass: ` markers, so the file matches what it was before install, and stops gpg-agent. If the markers are missing, it takes the original lines from the newest backup. It works when the app was moved or deleted, and it keeps the backups. To also delete the installed app, pass `--remove-app`.

To test the installer:

```sh
scripts/test-installer.sh
```

The tests run each case with a temporary `HOME` and `GNUPGHOME` and a stub `gpgconf`, so they don't touch your GnuPG setup or stop your gpg-agent.

## Run the demo

The demo shows scripted panel states with simulated card replies:

```sh
build/TouchGlass.app/Contents/MacOS/TouchGlass --demo sign
```

Scenarios: `sign`, `touch`, `timeout`, `wrong-pin`, `ssh`, `decrypt`, `blocked`, `passphrase`, `insert-card`, `message`, `removed`, `error`, and `all`, which runs every scenario in sequence. `--help` describes each one.

In the demo, any text in the PIN field continues. To simulate the touch, click **Simulate touch** in the demo controls window, or press Space while that window is focused. Without a touch, the demo touches after 4 seconds.

| Option | Effect |
| --- | --- |
| `--touch-after <seconds>` | Simulates the touch after this many seconds. |
| `--auto-submit <seconds>` | Submits PIN, passphrase and confirm prompts without typing. |
| `--slow <factor>` | Slows the panel animations down by this factor, to review them. |
| `--no-controls` | Hides the demo controls window. |
| `--focus-report` | Prints whether the PIN panel took key focus. |

The demo never reads, logs or prints what you type in the PIN field.

## Compare materials

```sh
build/TouchGlass.app/Contents/MacOS/TouchGlass --samples
```

This opens one sample panel per material variant, each in its own window, so each shows the real content behind it. Click a sample before judging it: the glass refracts at its edges only while its window is key. Drag a sample to move it over busy content. The app prints which label is which variant and each display's current and potential HDR headroom. Press Esc or click a close button to quit.

## Layout

- `TouchGlassCore`: panel states, copy, touch timing and a pure state machine (`PanelMachine`) that turns events into effects. It depends on Foundation and Observation only.
- `TouchGlassPanel`: the SwiftUI views and the AppKit panel window. `PanelController` performs the state machine's effects.
- `TouchGlassHost`: `HostCoordinator`, which merges proxy events and pinentry prompts into panel events and replies, and `HostServer`, which accepts helper connections.
- `TouchGlassIPC`: the messages and socket transport shared with the helpers.
- `TouchGlass`: the app: the host, plus the demo and sample modes.

## License

Apache License 2.0. See [LICENSE](LICENSE).
