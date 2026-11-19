# Contribute to TouchGlass

This page covers building TouchGlass from source, running the tests and the demo, capturing the README screenshots, and publishing a release.

## Build from source

To build TouchGlass, you need Swift 6 with the macOS 26 SDK or later. The Command Line Tools are enough; Xcode isn't required. To install them, run `xcode-select --install`.

```sh
scripts/build-app.sh
```

The script builds `build/TouchGlass.app` with Swift Package Manager and signs it ad hoc. The app has no Dock icon.

- To build the debug configuration, pass `debug`.
- To bundle the executables of an earlier `swift build` instead of building, pass `--prebuilt <directory>`, as the Homebrew formula does.
- To set the version in `Info.plist` and in `touchglass --version`, set `TOUCHGLASS_VERSION`. The default is `0.0.0-dev`, which isn't a release number: a host and helpers of a development build never make each other's host exit for a version mismatch, also next to a Homebrew install.

To install your build, run `scripts/touchglass install`. Run from a checkout, it builds the app if it is missing or older than the sources and copies it to `~/Applications`. See [Install and uninstall TouchGlass](docs/install.md).

Run without arguments, `TouchGlass.app` is the host: it listens on a Unix socket in `~/Library/Application Support/TouchGlass` for `touchglass-pinentry` and `touchglass-scdaemon`, and shows the panel for their prompts and card operations. For how the scdaemon proxy works, see [How touchglass-scdaemon works](docs/touchglass-scdaemon.md).

## Run the tests

To run the unit tests:

```sh
scripts/test.sh
```

The script passes the Swift Testing macro plugin path to `swift test`, because with only the Command Line Tools installed, the build sometimes fails to find that plugin. It passes other arguments on to `swift test`, such as `--filter ScdProxyTests`.

To run the installer tests:

```sh
scripts/test-installer.sh
```

The installer tests run each case with a temporary `HOME` and `GNUPGHOME` and stub `gpgconf`, `pgrep` and `pkill` commands. They don't touch your GnuPG setup, stop your gpg-agent or quit your TouchGlass host. The launcher tests run stub helpers that print their arguments and input.

The Tests workflow runs both suites and builds the app on macOS 26 for pull requests, pushes to `main` and version tags.

To drive the scdaemon proxy with a fake card instead of a YubiKey, see [Test tools](docs/touchglass-scdaemon.md#test-tools).

## Run the demo

The demo shows scripted panel states with simulated card replies. It involves no gpg and no card:

```sh
build/TouchGlass.app/Contents/MacOS/TouchGlass --demo sign
```

The scenarios are `sign`, `touch`, `timeout`, `wrong-pin`, `ssh`, `decrypt`, `blocked`, `passphrase`, `insert-card`, `message`, `removed`, `error`, `client` and `back-to-back`. `all`, the default, runs every scenario in sequence. `--help` describes each scenario.

In the demo, any text in the PIN field continues. To simulate the touch, click **Simulate touch** in the demo controls window, or press Space while that window is focused. Without either, the demo touches after 4 seconds. The demo never reads, logs or prints what you type in the PIN field.

| Option | Effect |
| --- | --- |
| `--touch-after <seconds>` | Simulates the touch after this many seconds. The default is 4. |
| `--auto-submit <seconds>` | Submits PIN, passphrase and confirm prompts without typing. |
| `--slow <factor>` | Slows the panel animations down by this factor, to review them. |
| `--no-controls` | Hides the demo controls window. |
| `--focus-report` | Prints whether the PIN panel took key focus. |
| `--appearance <look>` | Uses the `readable` (default) or `smoked` look, as the `appearance` setting in `host.conf` does. |
| `--client <label>` | Shows this label for what asked, instead of each scenario's sample label. |
| `--no-client` | Hides the client line, as `show-client = no` does. |
| `--color-scheme <scheme>` | Uses `light` or `dark` instead of the system appearance. |

## Capture screenshots

`scripts/screenshots.sh` captures panel states into `docs/images/` as PNG files at the screen's pixel scale:

```sh
scripts/screenshots.sh                      # every state, light and dark
scripts/screenshots.sh --states touch,ssh   # some states
scripts/screenshots.sh --dry-run            # print the steps without running them
```

The script builds `touchglass-screenshots`, a developer tool that shows the app's panel and isn't part of `TouchGlass.app`. It runs the tool once for each state and colour scheme, in front of a full-screen backdrop in GitHub's page colour: `#ffffff` for light and `#0d1117` for dark. Liquid Glass takes its tint from what is behind it, so each image looks right on that page colour only. Each image is the panel window, shadow included.

Each capture covers the screen for about 2 seconds, so leave the Mac alone while the script runs. The screen must be unlocked and awake. The tool captures its own windows, so the terminal needs no Screen Recording permission. `scripts/screenshots.sh --help` lists the options.

To show one state yourself, run `swift run touchglass-screenshots <state>`, and stop it with Control-C. `swift run touchglass-screenshots --help` lists the states.

## Publish a release

A release has three steps: build the notarized zip, push the tag and create the GitHub release, then update the Homebrew formula.

1. Build the zip:

   ```sh
   scripts/release.sh --dry-run 1.2.3
   scripts/release.sh 1.2.3
   ```

   The script builds the app with that version for Apple silicon and Intel Macs, signs the helpers and the app with the hardened runtime, notarizes the zip with `xcrun notarytool`, and staples the ticket. It writes `build/release/TouchGlass-<version>.zip` and prints the commands for the next step. It creates no tag or release itself. Except with `--dry-run`, it refuses a commit that isn't on `origin/main`, so the tag points at a commit that the Tests workflow ran for on `main`; push to `main` and run `git fetch origin` first.

2. Push the tag with the command that the script prints. The tag must look like `v1.2.3`. The Tests workflow runs the unit and installer tests on the tag; wait until that run passes, then create the GitHub release with the command that the script prints.

3. Run the Release workflow in [homebrew-touchglass](https://github.com/ambroos/homebrew-touchglass), from its Actions tab or with the GitHub CLI:

   ```sh
   gh workflow run release.yml -R ambroos/homebrew-touchglass -f version=1.2.3
   ```

   The workflow points the formula at the tag, builds and tests a bottle, publishes the bottle and commits the formula. Without a version, it releases the latest `v*.*.*` tag. The tap's README describes the workflow and how to run it again.

A release needs a Developer ID Application certificate in the keychain and notarization credentials stored with `xcrun notarytool store-credentials touchglass`. If the keychain holds more than one Developer ID identity, set `TOUCHGLASS_SIGN_IDENTITY`. To use another credentials profile, set `TOUCHGLASS_NOTARY_PROFILE`.

To test the script without a certificate, pass `--dry-run`: it signs ad hoc and skips notarization. To check the signature before the notarization credentials exist, pass `--no-notarize`: it signs with the Developer ID identity and skips notarization. Gatekeeper rejects the zip of either, so don't publish it.

## Repository layout

| Target | Contents |
| --- | --- |
| `TouchGlassCore` | Panel states, copy, touch timing, host settings and the state machine `PanelMachine`, which turns events into effects. Depends on Foundation and Observation only. |
| `TouchGlassPanel` | The SwiftUI views and the AppKit panel window. `PanelController` performs the state machine's effects. |
| `TouchGlassHost` | `HostCoordinator`, which merges proxy events and pinentry prompts into panel events and replies; `HostServer`, which accepts helper connections; and the lookup of what asked. |
| `TouchGlassIPC` | The messages and socket transport shared with the helpers. |
| `TouchGlass` | The app: the host and the demo. |
| `touchglass-pinentry` | The pinentry that gpg-agent runs. It forwards prompts to the host, or to the fallback pinentry. |
| `touchglass-scdaemon`, `ScdProxyCore` | The scdaemon proxy. See [How touchglass-scdaemon works](docs/touchglass-scdaemon.md). |
| `fake-scdaemon`, `fake-agent`, `fake-host`, `ScdTestSupport` | Test tools for the proxy. |
| `touchglass-screenshots` | Shows and captures one panel state for `scripts/screenshots.sh`. Not part of the app. |

The scripts are in `scripts/`: `touchglass` (the install command, bundled in the app), `build-app.sh`, `test.sh`, `test-installer.sh`, `screenshots.sh` and `release.sh`.
