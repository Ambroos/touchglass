# TouchGlass

TouchGlass is a macOS panel for YubiKey operations through gpg-agent. When a signature, SSH login or decryption needs the card, one floating Liquid Glass panel asks for the PIN, then shows "Touch your YubiKey" with a countdown to the card's touch timeout, then confirms and closes itself.

Run without arguments, the app is the host: it listens on a Unix socket for `touchglass-pinentry` and `touchglass-scdaemon` and shows the panel for their prompts and card operations. Installing those helpers into a gpg setup is not automated yet.

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

## Settings

The host reads `~/Library/Application Support/TouchGlass/host.conf`, one `key = value` per line, with `#` for comments:

| Key | Values | Effect |
| --- | --- | --- |
| `appearance` | `smoked` (default), `readable` | Smoked clear glass with HDR white text, or regular glass with standard label colours in light mode. |

The demo takes the same setting as `--appearance`.

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
