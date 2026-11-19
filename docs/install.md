# Install and uninstall TouchGlass

TouchGlass connects to gpg-agent through two lines in `gpg-agent.conf`: `pinentry-program` and `scdaemon-program`. The `touchglass` command sets up everything else and prints the change to those two lines. It edits `gpg-agent.conf` only when you pass `--apply`.

`gpg-agent.conf` is in `GNUPGHOME` if that variable is set, and in `~/.gnupg` otherwise.

## Get the app

With Homebrew:

```sh
brew install ambroos/touchglass/touchglass
```

The formula installs `gnupg` and `pinentry-mac` if they're missing, puts `TouchGlass.app` at `$(brew --prefix)/opt/touchglass/TouchGlass.app`, and links the `touchglass` command into Homebrew's `bin` directory. The tap provides bottles for Apple silicon; on an Intel Mac, Homebrew builds TouchGlass from source, which needs the Command Line Tools for macOS 26 or later. Installing the formula doesn't change your GnuPG setup.

Without Homebrew, download the signed and notarized `TouchGlass-<version>.zip` from the [TouchGlass releases on GitHub](https://github.com/ambroos/touchglass/releases). It runs on Apple silicon and Intel Macs. Move `TouchGlass.app` to `/Applications`, and use `/Applications/TouchGlass.app/Contents/Resources/touchglass` wherever this page says `touchglass`.

From a checkout of the repository, use `scripts/touchglass` wherever this page says `touchglass`. See [Build from source](../CONTRIBUTING.md#build-from-source).

## Connect TouchGlass to gpg-agent

```sh
touchglass install
```

Install writes TouchGlass's own files and changes nothing else:

1. Run from inside `TouchGlass.app`, as the Homebrew and release commands are, install uses that app where it is, unless you pass `--app-dir` or `--from`. Run from a checkout, it builds `build/TouchGlass.app` if it is missing or older than the sources, and copies it to `~/Applications`. To copy it elsewhere, pass `--app-dir <directory>`; to install a bundle that you built, pass `--from <path to TouchGlass.app>`.
2. It writes the path of the real scdaemon to `~/Library/Application Support/TouchGlass/scdaemon-program`. The path comes from the `scdaemon-program` line that `gpg-agent.conf` had before TouchGlass, else from an earlier install, else from `gpgconf --list-components`. For Homebrew's GnuPG, install prefers a stable path such as `/opt/homebrew/opt/gnupg/libexec/scdaemon` over the versioned `Cellar` path, which a GnuPG upgrade removes.
3. If `~/Library/Application Support/TouchGlass/pinentry.conf` doesn't exist, it writes the file with `fallback-pinentry` set to the pinentry that `gpg-agent.conf` named before, else `pinentry-mac`, else the pinentry that `gpgconf --list-components` reports. A pinentry that isn't executable doesn't count. On a later install, it replaces a `fallback-pinentry` that no longer exists and keeps one that works. If it finds no pinentry, it warns and leaves the setting out.
4. It writes two launchers, `touchglass-pinentry` and `touchglass-scdaemon`, to `~/Library/Application Support/TouchGlass/bin`, and copies the `touchglass` command next to them. Each launcher runs the helper of the same name in the app. While the app is missing, for example during `brew upgrade`, the pinentry launcher runs the fallback pinentry and the scdaemon launcher runs the real scdaemon, so card operations keep working without the panel.
5. It prints the change to make in `gpg-agent.conf` and the command that restarts gpg-agent.

The printed change replaces your `pinentry-program` and `scdaemon-program` lines with these two, with your home directory in the paths:

```text
pinentry-program /Users/you/Library/Application Support/TouchGlass/bin/touchglass-pinentry
scdaemon-program /Users/you/Library/Application Support/TouchGlass/bin/touchglass-scdaemon
```

Your original lines stay in the file as comments that start with `# touchglass: `. For an option that wasn't set, the new line goes at the end of the file, after a `# touchglass: added <option>` comment. `touchglass uninstall` uses these comments to restore the file.

After you edit the file, stop gpg-agent so that it reads the file on next use:

```sh
gpgconf --kill gpg-agent
```

gpg-agent forgets its cached PINs and passphrases, so the next card operation asks for the PIN again.

### Apply the change with `--apply`

To have install edit `gpg-agent.conf` and stop gpg-agent, preview the edit as a diff, then apply it:

```sh
touchglass install --apply --dry-run
touchglass install --apply
```

`--apply` first backs up `gpg-agent.conf` to `gpg-agent.conf.touchglass-backup-<timestamp>` next to it. It then makes the edit that install prints and changes no other line. If the GnuPG home doesn't exist, it creates it with mode 700.

If `gpg-agent.conf` names the helpers inside `TouchGlass.app` directly, as installs before the launchers did, install prints those lines with their replacements, and `--apply` replaces them and keeps the `# touchglass: ` comments.

## Upgrade

`brew upgrade touchglass` needs no new `touchglass install`, because the launchers run the app at Homebrew's `opt` path, which follows upgrades.

After a helper of the new version connects, the running TouchGlass host quits when it has nothing left to show, and the next prompt or card operation starts the new host. A running scdaemon keeps the previous version until it stops, which can take days. To switch both now:

```sh
pkill -x TouchGlass
gpgconf --kill scdaemon
```

The card locks again when scdaemon stops, so the next card operation asks for the PIN again.

From a checkout, run `scripts/touchglass install` again after you pull changes. It replaces the installed app and rewrites the launchers, and leaves `gpg-agent.conf` as it is. It prints the two preceding commands for you to run; with `--apply`, it runs them itself. Install copies the new app next to the old one and then swaps them, so a failed copy leaves the installed app whole.

## Check the setup

```sh
touchglass status
```

Status shows what `gpg-agent.conf` points at, which app the launchers run, whether the host and the scdaemon proxy are running, which pinentry the launchers fall back to, and the `gpg-agent.conf` backups.

## Uninstall

```sh
touchglass uninstall
```

Uninstall prints how to restore the original `pinentry-program` and `scdaemon-program` lines, and the `gpgconf --kill gpg-agent` command. While `gpg-agent.conf` names the launchers, it keeps them, because gpg-agent runs them for every prompt and card operation. After you change the file and stop gpg-agent, run uninstall again to remove the launchers and the copy of the command.

To have uninstall restore the lines and stop gpg-agent, pass `--apply`; `--dry-run` previews it:

```sh
touchglass uninstall --apply --dry-run
touchglass uninstall --apply
```

`--apply` restores the lines from the `# touchglass: ` comments, so the file matches what it was before install. If the comments are missing, it takes the original lines from the newest backup. If it finds a TouchGlass line without a comment next to a commented-out line for the same option, it can't tell whether that line is your earlier setting, so it changes nothing and prints the manual steps. After it stops gpg-agent, it removes the launchers.

Uninstall keeps the launchers, and says why, while a gpg-agent runs that started before `gpg-agent.conf` last changed, or while the `gpg-agent.conf` of another GnuPG home that you ran install for still names them. After `--apply` stopped this home's gpg-agent, a gpg-agent that still runs and started before the change belongs to another GnuPG home, so uninstall keeps the launchers for it too; stop it with `gpgconf --kill gpg-agent` and `GNUPGHOME` set to its directory, then run uninstall again.

To also delete the installed app, pass `--remove-app`. For the app that Homebrew installed, run `brew uninstall touchglass` instead, after uninstall restored `gpg-agent.conf`.

To check whether anything still refers to TouchGlass before you delete its files, run `touchglass uninstall --check`. It exits with status 1 while `gpg-agent.conf` or the launchers still refer to TouchGlass.

Uninstall leaves these behind:

- The `gpg-agent.conf.touchglass-backup-<timestamp>` files next to `gpg-agent.conf`.
- `~/Library/Application Support/TouchGlass`, which holds `pinentry.conf`, `scdaemon-program`, `host.conf` if you wrote one, and the host's socket. A later install reuses `pinentry.conf`.
- The app's preferences, such as the sound settings.
- The installed app, unless you pass `--remove-app`.
- A running host. To quit it, run `pkill -x TouchGlass`.

To remove the settings and preferences too:

```sh
rm -r ~/Library/Application\ Support/TouchGlass
defaults delete io.ambroos.touchglass
```

`defaults delete` reports an error if you never changed a sound setting, because there is nothing to remove.

## Troubleshoot

If the panel doesn't appear for a card operation, run `touchglass status`. If it reports that scdaemon runs without the proxy, gpg-agent started the real scdaemon while the app was missing, for example during `brew upgrade`. Stop it, and the next card operation starts it through the launcher:

```sh
gpgconf --kill scdaemon
```

If PIN prompts appear in `pinentry-mac` instead of the panel, the pinentry couldn't reach or start the host. Check that `touchglass status` shows the app where you expect it. For diagnostic lines from the pinentry, set `log-file` in `pinentry.conf`; see [Pinentry settings](configuration.md#pinentry-settings).

If you removed the Homebrew formula before you restored `gpg-agent.conf`, gpg-agent keeps working without the panel, because the launchers fall back to the real scdaemon and a plain pinentry. `brew uninstall` can also remove `pinentry-mac` if you didn't install it yourself; the pinentry launcher then uses Homebrew's `pinentry`, which asks for the PIN in the terminal. To restore `gpg-agent.conf`, run the copy of the command that install keeps next to the launchers:

```sh
~/Library/Application\ Support/TouchGlass/bin/touchglass uninstall
```
