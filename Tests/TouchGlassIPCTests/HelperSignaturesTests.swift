import Darwin
import Foundation
import Testing
@testable import TouchGlassIPC

/// The peer in every test is this test process: a directory that holds a copy of its executable under a
/// helper's name trusts it, and one that holds another binary does not.
@Suite(.serialized) struct HelperSignaturesTests {
    func temporaryDirectory() throws -> String {
        let directory = NSTemporaryDirectory() + "tg-helpers-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    func ownExecutable() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(getpid(), $0.baseAddress, UInt32($0.count)) }
        try #require(length > 0)
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Both ends of a socket pair belong to this process, so either end's peer is this process.
    func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    func install(_ source: String, as name: String, in directory: String) throws {
        let target = directory + "/" + name
        try? FileManager.default.removeItem(atPath: target)
        try FileManager.default.copyItem(atPath: source, toPath: target)
    }

    @Test func trustsAPeerRunningAHelperFromItsDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try install(try ownExecutable(), as: "touchglass-pinentry", in: directory)
        let (a, b) = try socketPair()
        defer { close(a); close(b) }
        #expect(HelperSignatures(directory: directory).allows(socket: a))
    }

    @Test func refusesAnyOtherPeer() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (a, b) = try socketPair()
        defer { close(a); close(b) }
        // No helpers at all.
        #expect(!HelperSignatures(directory: directory).allows(socket: a))
        // Helpers that are other programs.
        try install("/bin/sleep", as: "touchglass-pinentry", in: directory)
        try install("/bin/cat", as: "touchglass-scdaemon", in: directory)
        #expect(!HelperSignatures(directory: directory).allows(socket: a))
    }

    @Test func readsReplacedHelpersAgain() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (a, b) = try socketPair()
        defer { close(a); close(b) }
        let signatures = HelperSignatures(directory: directory)
        try install("/bin/sleep", as: "touchglass-scdaemon", in: directory)
        #expect(!signatures.allows(socket: a))
        // An upgrade that replaces the file in place: its helpers must still reach the old host.
        try install(try ownExecutable(), as: "touchglass-scdaemon", in: directory)
        #expect(signatures.allows(socket: a))
    }

    @Test func trustsTheOptLinkOfAHomebrewKeg() {
        let host = "/opt/homebrew/Cellar/touchglass/0.1.2/TouchGlass.app/Contents/MacOS/TouchGlass"
        #expect(HelperSignatures.trustedDirectories(hostExecutable: host) == [
            "/opt/homebrew/Cellar/touchglass/0.1.2/TouchGlass.app/Contents/MacOS",
            "/opt/homebrew/opt/touchglass/TouchGlass.app/Contents/MacOS",
        ])
        #expect(HelperSignatures.trustedDirectories(hostExecutable: "/Applications/TouchGlass.app/Contents/MacOS/TouchGlass")
            == ["/Applications/TouchGlass.app/Contents/MacOS"])
        #expect(HelperSignatures.homebrewOptPath("/usr/local/Cellar/touchglass/0.1.2") == nil)
        #expect(HelperSignatures.homebrewOptPath("/usr/local/Cellar/touchglass/0.1.2/bin") == "/usr/local/opt/touchglass/bin")
    }

    /// `brew upgrade` deletes the keg that the host runs from and points the `opt` link at the next one.
    /// The next release's helpers run through the link, and must reach the old host to make it retire.
    @Test func admitsTheNextReleaseAfterAnUpgradeDeletedTheHostsKeg() throws {
        let prefix = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: prefix) }
        let macOS = "/TouchGlass.app/Contents/MacOS"
        let oldKeg = prefix + "/Cellar/touchglass/0.1.2"
        let newKeg = prefix + "/Cellar/touchglass/0.1.3"
        let opt = prefix + "/opt/touchglass"
        try FileManager.default.createDirectory(atPath: oldKeg + macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: prefix + "/opt", withIntermediateDirectories: true)
        try install("/bin/sleep", as: "touchglass-pinentry", in: oldKeg + macOS)
        try FileManager.default.createSymbolicLink(atPath: opt, withDestinationPath: "../Cellar/touchglass/0.1.2")

        let signatures = HelperSignatures.forHost(executablePath: oldKeg + macOS + "/TouchGlass")
        let (a, b) = try socketPair()
        defer { close(a); close(b) }
        #expect(!signatures.allows(socket: a))

        try FileManager.default.createDirectory(atPath: newKeg + macOS, withIntermediateDirectories: true)
        try install(try ownExecutable(), as: "touchglass-pinentry", in: newKeg + macOS)
        try FileManager.default.removeItem(atPath: opt)
        try FileManager.default.createSymbolicLink(atPath: opt, withDestinationPath: "../Cellar/touchglass/0.1.3")
        try FileManager.default.removeItem(atPath: oldKeg)
        #expect(signatures.allows(socket: a))

        // The link only says where to look: a file there must still match the peer's hash.
        try install("/bin/cat", as: "touchglass-pinentry", in: newKeg + macOS)
        #expect(!signatures.allows(socket: a))
    }

    @Test func serverClosesARefusedConnection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "/tmp/tg-\(getpid())-\(UInt32.random(in: 0...UInt32.max))/host.sock"
        let server = try IPCServer(path: path, peerVerifier: HelperSignatures(directory: directory))
        let accepting = Thread { _ = try? server.accept() }
        accepting.start()
        defer { server.close() }

        let client = try IPCClient.connect(path: path)
        #expect(throws: IPCError.closed) { try client.receive(timeout: 2) }
    }
}
