import Foundation
import ScdProxyCore

// gpg-agent runs this program as `scdaemon-program`. It starts the real scdaemon and relays its traffic;
// see ScdaemonProxy for the process rules.

guard let config = ProxyConfig.resolve() else {
    FileHandle.standardError.write(Data("touchglass-scdaemon: no scdaemon found; set \(ProxyConfig.scdaemonEnvironmentKey)\n".utf8))
    exit(2)
}
ScdaemonProxy(config: config).run(arguments: Array(CommandLine.arguments.dropFirst()))
