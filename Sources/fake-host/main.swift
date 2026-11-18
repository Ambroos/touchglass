// Listens on the TouchGlass host socket and prints every message it receives as one JSON line.
//
//   fake-host [--socket <path>]
//
// The default path is the host socket (TOUCHGLASS_SOCKET overrides it). Use it to watch what
// touchglass-scdaemon and touchglass-pinentry send, or as a host that tests can stop with SIGSTOP.

import Foundation
import ScdTestSupport
import TouchGlassIPC

var path = IPCPaths.hostSocket
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--socket":
        guard let value = args.popFirst() else { fatalError("--socket needs a path") }
        path = value
    default:
        FileHandle.standardError.write(Data("usage: fake-host [--socket <path>]\n".utf8))
        exit(64)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
do {
    _ = try FakeHost(path: path) { message in
        if let line = try? IPCLine.encode(message) {
            FileHandle.standardOutput.write(line)
        }
    }
    FileHandle.standardError.write(Data("fake-host: listening on \(path)\n".utf8))
    while true { sleep(3600) }
} catch {
    FileHandle.standardError.write(Data("fake-host: \(error)\n".utf8))
    exit(1)
}
