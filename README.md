# TouchGlass

TouchGlass is a macOS panel for YubiKey operations through gpg-agent. When a signature, SSH login or decryption needs the card, one floating Liquid Glass panel asks for the PIN, then shows "Touch your YubiKey" with a countdown to the card's touch timeout, then confirms and closes itself.

This repository contains the panel and a demo mode. The gpg-agent integration is not built yet, so the app does not talk to gpg-agent, scdaemon or a card.

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
swift test
```

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

This opens one sample panel per material: `NSGlassEffectView` in each style, SwiftUI `glassEffect` variants, and two `NSVisualEffectView` materials as a baseline. Each sample is its own window, so it shows the real content behind it. Drag a sample to move it over busy content. The app prints which number is which material. Press Esc or click a close button to quit.

## Layout

- `TouchGlassCore`: panel states, copy, touch timing and a pure state machine (`PanelMachine`) that turns events into effects. It depends on Foundation and Observation only.
- `TouchGlassPanel`: the SwiftUI views and the AppKit panel window. `PanelController` performs the state machine's effects.
- `TouchGlass`: the app, which currently runs the demo.

## License

Apache License 2.0. See [LICENSE](LICENSE).
