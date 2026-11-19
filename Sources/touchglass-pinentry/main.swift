// touchglass-pinentry: the pinentry-program for gpg-agent. See PinentryServer.
import TouchGlassIPC

// After a Homebrew upgrade, rewrites the launchers in the background if they are older than this release.
LauncherRefresher.forThisProcess(category: .pinentry).refreshIfNeeded()
PinentryServer(config: Config.load(), arguments: Array(CommandLine.arguments.dropFirst())).run()
