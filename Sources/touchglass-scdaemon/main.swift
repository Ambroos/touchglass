import Foundation
import ScdProxyCore
import TouchGlassIPC

// gpg-agent runs this program as `scdaemon-program`. It starts the real scdaemon and relays its traffic;
// see ScdaemonProxy for the process rules.

// After a Homebrew upgrade, rewrites the launchers in the background if they are older than this release.
LauncherRefresher.forThisProcess(category: .scdaemon).refreshIfNeeded()

guard let config = ProxyConfig.resolve() else {
    FileHandle.standardError.write(Data("touchglass-scdaemon: no scdaemon found; set \(ProxyConfig.scdaemonEnvironmentKey)\n".utf8))
    exit(2)
}
let arguments = Array(CommandLine.arguments.dropFirst())
let gnupg = ProxyConfig.gnupgContext(arguments: arguments)
ScdaemonProxy(config: config, gnupg: gnupg).run(arguments: arguments)
