# Configure TouchGlass

TouchGlass works without configuration. Three places hold its settings: `host.conf` for the panel, the app's user defaults for sounds, and `pinentry.conf` for the pinentry helper. Both files are in `~/Library/Application Support/TouchGlass`, with one `key = value` per line and `#` at the start of a comment line. The host and the pinentry ignore unknown keys and invalid values. TouchGlass also learns the touch policy of each YubiKey you use and keeps it in `cards.conf` in the same directory; see [Touch policies](#touch-policies).

## Panel settings

The host reads `~/Library/Application Support/TouchGlass/host.conf` when it starts:

| Key | Values | Effect |
| --- | --- | --- |
| `appearance` | `readable` (default), `smoked` | `readable` is regular glass with standard label colours. `smoked` is clear glass with dark smoke and HDR white text. |
| `show-client` | `yes` (default), `no` | Shows what asked for the card operation under the detail line, such as `git commit · touchglass` or `ssh build-box`. See [How TouchGlass labels what asked](#how-touchglass-labels-what-asked). |
| `touch-timeout` | Seconds, 1 to 600 | Sets the length of the touch countdown. Without it, the countdown uses the card's touch timeout that `touchglass-scdaemon` reports, 15 seconds. Set it only if your card waits for a different time. |
| `touch-cache` | `auto` (default), or seconds, 0 to 600 | How the panel times the touch step after an operation that the card completed. `auto` follows the touch policy of each key; see [Touch policies](#touch-policies). A number of seconds applies to every card and key, whatever TouchGlass learned: within that time after an operation that the card completed, the panel shows the touch step only after the card stays silent for 1.5 seconds instead of 0.4, and shows nothing for an operation that finishes sooner. `0` shows the touch step after 0.4 seconds for every operation. |

The reminder sounds and the urgent phase of the countdown keep their proportions for any `touch-timeout`: they start at a third and at two thirds of the countdown. If `touch-timeout` is shorter than the card's own timeout, the countdown reaches 0 and the panel stays until the card answers.

For example, to use the smoked look and hide the label:

```text
appearance = smoked
show-client = no
```

After you change `host.conf`, quit the host so that it reads the file again:

```sh
pkill -x TouchGlass
```

The helpers start the host again on the next prompt or card operation.

## Touch policies

A YubiKey sets a touch policy for each of its three OpenPGP keys: the signature, decryption and authentication key. The policy decides when the card waits for a touch, and the card sends nothing while it waits, so TouchGlass needs the policy to time the touch step. With `touch-cache = auto`, the default, the host times each operation by the policy of the key it uses:

| Policy | What the card does | What the panel does |
| --- | --- | --- |
| `cached`, `cached-fixed` | Waits for a touch, then accepts operations without one for 15 seconds after each use. | Within 15 seconds after the card's last operation, shows the touch step only after the card stays silent for 1.5 seconds, and nothing for an operation that finishes sooner. Otherwise, after 0.4 seconds. |
| `on`, `fixed` | Waits for a touch for every operation. | Shows the touch step after 0.4 seconds. |
| `off` | Never waits for a touch. | Shows no touch step when the card is slow to answer. |
| Not learned yet | Any of these. | As for `cached`. |

The `fixed` variants can't change without replacing the key; for the panel, they behave as the others. For a card from another maker, the host uses the `cached` timing whatever the card reports, because the cached policies and the 15-second window are Yubico's.

TouchGlass reads the policies from the card's User Interaction Flag data objects. Reading them needs no PIN and no touch. The host learns them in two ways:

- When gpg-agent reads the card's data, for example for `gpg --card-status`, the policies pass through `touchglass-scdaemon`, which reports them to the host.
- After an operation on a YubiKey whose policy the host doesn't know, the host asks gpg-agent once, 3 seconds after the operation ended and while no other operation runs. It runs `gpg-connect-agent --no-autostart --homedir <your GnuPG home> 'scd serialno --demand=<card serial>' 'scd getattr UIF' /bye`. The first command picks the card the way gpg-agent does before each operation, so with several cards attached, the host reads the right one. The host asks again if a key it learned as `off` waits for a touch until the card times out, at most once a minute.

The host stores the policies in `~/Library/Application Support/TouchGlass/cards.conf`, one card per line, and reads the file again when it changes. A reading replaces what the file held for that card.

To read the policies of the attached cards yourself and store them, run:

```sh
touchglass card
```

The command shows each card's serial and the policy of each key. `touchglass install` does the same when a card is attached, and `touchglass status` lists what TouchGlass learned. After you change a policy with `ykman openpgp keys set-touch`, run `touchglass card`, so the panel doesn't wait for an operation to show the change.

To ignore the learned policies, set `touch-cache` in `host.conf` to a number of seconds; see [Panel settings](#panel-settings). `gpg --card-status` prints the `cached` policies as `on`, so to see a key's exact policy, use `touchglass card` or `ykman openpgp info`.

## Read the log

The helpers and the host write to the unified log under the subsystem `io.ambroos.touchglass`, with the categories `scdaemon`, `host` and `pinentry`. The log holds operation kinds, the last 4 digits of card serials, results, durations, panel state names, connection news, and each time the panel takes or gives back keyboard focus, with the bundle ID of the frontmost app. It never holds a PIN, a passphrase, the data that is signed or decrypted, or key material.

To watch the log while you use the card:

```sh
log stream --predicate 'subsystem == "io.ambroos.touchglass"' --level info
```

To read the last 10 minutes afterwards:

```sh
log show --last 10m --predicate 'subsystem == "io.ambroos.touchglass"' --info
```

With `--level debug` for `log stream`, or `--debug` for `log show`, the log also shows every scdaemon command with its duration and each Assuan keyword that the pinentry handles. To show one component, add a category to the predicate, such as `subsystem == "io.ambroos.touchglass" AND category == "scdaemon"`.

To check the touch timing, look at the `op end` lines of the `scdaemon` category. Each one gives the time the card took after the command or the PIN. Operations that the cached touch covers take that time without a touch; the host's `touch wait inside … cache window` and `nothing shown` lines show which operations it held back. The host's `touch policy` lines show what it learned for each card, and when it asked gpg-agent.

If focus leaves your terminal unexpectedly, look at the `panel: make key` and `panel: release key` lines of the `host` category. Each one names the panel state, why the panel asked for focus, and the frontmost app before and after.

## Sounds

The panel is silent by default. To turn sounds on:

```sh
defaults write io.ambroos.touchglass soundsEnabled -bool true
```

With sounds on, the panel plays system sounds at the alert volume: Tink when the touch step starts, Ping as a reminder during the touch countdown, Basso when an operation fails, and your alert sound for a wrong PIN or passphrase. To keep the other sounds but turn off the reminders:

```sh
defaults write io.ambroos.touchglass reminderSoundsEnabled -bool false
```

The host reads both settings each time it plays a sound, so a change applies without a restart. To go back to silent:

```sh
defaults delete io.ambroos.touchglass soundsEnabled
```

## Pinentry settings

`touchglass-pinentry` reads `~/Library/Application Support/TouchGlass/pinentry.conf` each time gpg-agent starts it. `touchglass install` writes the file with `fallback-pinentry` set; see [Connect TouchGlass to gpg-agent](install.md#connect-touchglass-to-gpg-agent).

| Key | Default | Effect |
| --- | --- | --- |
| `fallback-pinentry` | The first executable of `/opt/homebrew/bin/pinentry-mac`, `/usr/local/bin/pinentry-mac`, `/opt/homebrew/bin/pinentry` and `/usr/local/bin/pinentry` | The pinentry that takes over a prompt when the host isn't reachable or stops answering. If the configured file isn't executable, the pinentry uses the default. |
| `host-app` | The `TouchGlass.app` that contains the pinentry | The app to start when the host isn't running: a bundle path, an app name, or `none` to never start it. |
| `connect-timeout-ms` | `300` | How long a connection to the host socket can take, in milliseconds. |
| `launch-timeout-ms` | `2000` | How long to wait for a host that the pinentry started to accept connections, in milliseconds. |
| `ping-interval-ms` | `1000` | How often the pinentry checks that the host still answers while a prompt shows, in milliseconds. |
| `host-stall-ms` | `3000` | How long the host can go without answering before the pinentry hands the prompt to the fallback, in milliseconds. |
| `log-file` | None | A file for diagnostic lines: message types and Assuan keywords, never a PIN or passphrase. The same lines always go to the unified log; see [Read the log](#read-the-log). |

## How TouchGlass labels what asked

gpg-agent doesn't tell scdaemon or the pinentry which command needs the card, so the host infers it. For a PIN prompt, it uses the client process ID that gpg-agent passes to the pinentry. For a touch without a PIN prompt, it lists gpg-agent's connected clients by matching the agent's Unix sockets with the sockets of your other processes: an ssh client on the agent's SSH socket for an SSH login, and any other client for a signature or decryption. From that process, it walks up a few parent processes and reads their arguments and working directory:

- Under git, the label is the git subcommand and the repository's directory name, such as `git commit · touchglass`. `git push`, `git pull` and `git fetch` add the remote name, or only the host when the command names a URL. The repository name comes from the directory that git runs in; TouchGlass reads no files in the repository.
- An ssh client outside git shows its destination host.
- Any other process shows its executable name, such as `gpg`.

The panel opens without waiting for the label, which fills in when the lookup finishes. The lookup gives up after 50 milliseconds. If several clients match and their labels differ, the panel shows no label.
