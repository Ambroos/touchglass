import Darwin
import Foundation
import TouchGlassCore
import TouchGlassIPC

/// The touch policies that TouchGlass learned for one card.
public struct CardTouchPolicy: Sendable, Equatable {
    /// The card's serial as scdaemon reports it: for an OpenPGP card, the 32-digit application ID in hex.
    public var serial: String
    /// The policy per OpenPGP key slot: 1 sig, 2 dec, 3 aut. A slot without an entry is unknown.
    public var slots: [Int: TouchPolicy]

    public init(serial: String, slots: [Int: TouchPolicy]) {
        self.serial = serial.uppercased()
        self.slots = slots
    }

    /// The serial printed on the card; see `HostCoordinator.displaySerial`.
    public var displaySerial: String { HostCoordinator.displaySerial(serial) }

    /// Whether the serial is an OpenPGP application ID with Yubico's manufacturer ID, 0006.
    public var isYubico: Bool { Self.isYubico(serial) }

    public static func isYubico(_ serial: String) -> Bool {
        CardSerial.isOpenPGP(serial) && serial.uppercased().dropFirst(16).prefix(4) == "0006"
    }

    /// The slots as the log and `cards.conf` name them: "sign cached, decrypt on, auth off".
    public var summary: String {
        CardPolicyFile.slotNames.enumerated().map { index, name in
            "\(name) \(slots[index + 1]?.rawValue ?? "unknown")"
        }.joined(separator: ", ")
    }
}

/// `cards.conf` in the support directory: one learned card per line, `<serial> = <sign> <decrypt> <auth>`,
/// where each policy is `off`, `on`, `fixed`, `cached`, `cached-fixed` or `unknown`. `#` starts a comment
/// line. The host and `touchglass card` both write it, each by renaming a complete file over it.
public enum CardPolicyFile {
    public static let fileName = "cards.conf"
    /// The most cards the host keeps and reads, so a peer that reports serial after serial can't grow the
    /// file without limit.
    public static let maxCards = 64
    static let slotNames = ["sign", "decrypt", "auth"]

    public static func parse(_ text: String) -> [CardTouchPolicy] {
        var cards: [String: CardTouchPolicy] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let serial = trimmed[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            guard CardSerial.isValid(serial) else { continue }
            guard cards[serial] != nil || cards.count < maxCards else { continue }
            let words = trimmed[trimmed.index(after: equals)...].split(whereSeparator: { $0 == " " || $0 == "\t" })
            var slots: [Int: TouchPolicy] = [:]
            for (index, word) in words.prefix(3).enumerated() {
                if let policy = TouchPolicy(rawValue: String(word)) { slots[index + 1] = policy }
            }
            if cards[serial] == nil { order.append(serial) }
            cards[serial] = CardTouchPolicy(serial: serial, slots: slots)
        }
        return order.compactMap { cards[$0] }
    }

    public static func format(_ cards: [CardTouchPolicy]) -> String {
        var text = """
            # Touch policies that TouchGlass learned from your cards, one card per line:
            # <card serial> = <signature key> <decryption key> <authentication key>
            # TouchGlass and `touchglass card` rewrite this file. To use one touch cache window for every
            # card instead, set touch-cache in host.conf.

            """
        for card in cards.sorted(by: { $0.serial < $1.serial }) {
            let words = (1...3).map { card.slots[$0]?.rawValue ?? "unknown" }
            text += "\(card.serial) = \(words.joined(separator: " "))\n"
        }
        return text
    }

    /// The `S UIF-<n>` lines of gpg-connect-agent's output, if its `S SERIALNO` line names `serial` and
    /// it ends without an error. A card without a button answers `GETATTR UIF` with an error: that gives
    /// no slots. Nil when the output names another card, or none.
    public static func parseQueryOutput(_ output: String, serial: String) -> [Int: TouchPolicy]? {
        var named = false
        var slots: [Int: TouchPolicy] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 2, words[0] == "S" else { continue }
            if words[1] == "SERIALNO" {
                guard words.count >= 3, words[2].uppercased() == serial.uppercased() else { return nil }
                named = true
            } else if named, words[1].hasPrefix("UIF-"), let slot = Int(words[1].dropFirst(4)), (1...3).contains(slot),
                      words.count >= 3, let byte = UIFValue.firstByte(words[2]), let policy = TouchPolicy(uif: byte) {
                slots[slot] = policy
            }
        }
        return named ? slots : nil
    }
}

/// Reads and writes `cards.conf`.
public final class CardPolicyStore: @unchecked Sendable {
    public let path: String
    private var lastSeen: (mtime: timespec, size: off_t)?

    public init(path: String = IPCPaths.supportDirectory + "/" + CardPolicyFile.fileName) {
        self.path = path
    }

    /// The file's cards, or none when it is missing or unreadable.
    public func load() -> [CardTouchPolicy] {
        lastSeen = stamp()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return CardPolicyFile.parse(text)
    }

    /// The file's cards if it changed since the last load or save, such as by `touchglass card`; else nil.
    public func reloadIfChanged() -> [CardTouchPolicy]? {
        let now = stamp()
        if let now, let lastSeen, now.mtime.tv_sec == lastSeen.mtime.tv_sec, now.mtime.tv_nsec == lastSeen.mtime.tv_nsec, now.size == lastSeen.size {
            return nil
        }
        if now == nil && lastSeen == nil { return nil }
        return load()
    }

    /// Writes the cards by renaming a complete file over the old one. Returns false if that failed.
    @discardableResult
    public func save(_ cards: [CardTouchPolicy]) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        let staged = directory + "/.cards.conf.\(getpid()).\(UInt32.random(in: 0...UInt32.max))"
        guard FileManager.default.createFile(atPath: staged, contents: Data(CardPolicyFile.format(cards).utf8), attributes: [.posixPermissions: 0o644]) else {
            return false
        }
        guard rename(staged, path) == 0 else {
            unlink(staged)
            return false
        }
        lastSeen = stamp()
        return true
    }

    private func stamp() -> (mtime: timespec, size: off_t)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (info.st_mtimespec, info.st_size)
    }
}

/// Asks gpg-agent for a card's touch policies.
public protocol CardPolicyQuerying: Sendable {
    /// The policies per slot of the card with `serial`, or nil when the query failed or found another card.
    /// Blocks; the session calls it off the main thread.
    func query(serial: String, gnupg: GnuPGContext) -> [Int: TouchPolicy]?
}

/// Runs `gpg-connect-agent --no-autostart --homedir <home> 'scd serialno --demand=<serial>' 'scd getattr UIF' /bye`.
///
/// gpg-agent sends the same `SERIALNO --demand` before each card operation to pick the card, so with several
/// cards attached the query reads the one it names, and scdaemon serializes it with the agent's own
/// commands. Neither command needs a PIN or a touch. `--no-autostart` keeps it from starting a gpg-agent.
///
/// The host finds `gpg-connect-agent` itself, never from a peer: in the `bin` directory next to the
/// `libexec` directory of the real scdaemon that `touchglass install` recorded in `scdaemon-program`, then
/// in `fallbackBinDirectories`. A process that can write the support directory can already replace the
/// launchers, so this trusts nothing new.
public struct GnuPGCardPolicyQuery: CardPolicyQuerying {
    /// Where to look for gpg-connect-agent after the recorded scdaemon's `bin` directory.
    public static let fallbackBinDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/MacGPG2/bin", "/opt/local/bin"]
    public static let timeout: TimeInterval = 10
    /// How long a query may take to exit after `SIGTERM` before it gets `SIGKILL`.
    public static let killGrace: TimeInterval = 2
    /// The most output the host reads; the real answer is a few hundred bytes.
    public static let outputLimit = 64 * 1024

    private let homeDirectory: String
    private let supportDirectory: String
    private let fallbackDirectories: [String]
    private let timeout: TimeInterval

    public init(homeDirectory: String = IPCPaths.homeDirectory, supportDirectory: String = IPCPaths.supportDirectory, fallbackDirectories: [String] = Self.fallbackBinDirectories, timeout: TimeInterval = Self.timeout) {
        self.homeDirectory = homeDirectory
        self.supportDirectory = supportDirectory
        self.fallbackDirectories = fallbackDirectories
        self.timeout = timeout
    }

    public func arguments(serial: String, gnupg: GnuPGContext) -> [String] {
        ["--no-autostart", "--homedir", gnupg.home ?? homeDirectory + "/.gnupg", "scd serialno --demand=\(serial)", "scd getattr UIF", "/bye"]
    }

    public func executable() -> String? {
        var directories = fallbackDirectories
        if let text = try? String(contentsOfFile: supportDirectory + "/scdaemon-program", encoding: .utf8),
           let line = text.split(whereSeparator: \.isNewline).first {
            let libexec = (line.trimmingCharacters(in: .whitespaces) as NSString).deletingLastPathComponent
            if libexec.hasPrefix("/"), libexec.hasSuffix("/libexec") {
                directories.insert((libexec as NSString).deletingLastPathComponent + "/bin", at: 0)
            }
        }
        return directories.map { $0 + "/gpg-connect-agent" }.first { access($0, X_OK) == 0 }
    }

    public func query(serial: String, gnupg: GnuPGContext) -> [Int: TouchPolicy]? {
        // The serial goes into an Assuan command line, the home into an argument.
        guard CardSerial.isValid(serial), gnupg.isUsable, let executable = executable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(serial: serial, gnupg: gnupg)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let reader = LimitedReader(fd: output.fileHandleForReading.fileDescriptor, limit: Self.outputLimit)
        let readDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [process] in
            reader.run()
            // Too much output: no answer to wait for.
            if reader.overLimit { process.terminate() }
            readDone.signal()
        }
        var finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished {
            process.terminate()
            if exited.wait(timeout: .now() + Self.killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + Self.killGrace)
            }
        }
        // A child of the query that still holds the pipe can't keep the reader, and the queue, forever.
        if readDone.wait(timeout: .now() + 1) == .timedOut {
            reader.stop()
            _ = readDone.wait(timeout: .now() + 1)
            finished = false
        }
        withExtendedLifetime(output) {}
        guard finished, !reader.overLimit, process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return CardPolicyFile.parseQueryOutput(String(decoding: reader.data, as: UTF8.self), serial: serial)
    }
}

/// Reads a pipe until end of file, `limit` bytes, or `stop()`.
final class LimitedReader: @unchecked Sendable {
    private let fd: Int32
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var stopped = false
    private(set) var overLimit = false

    init(fd: Int32, limit: Int) {
        self.fd = fd
        self.limit = limit
    }

    var data: Data { lock.withLock { buffer } }

    func stop() { lock.withLock { stopped = true } }

    func run() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { return }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            let full = lock.withLock { () -> Bool in
                buffer.append(contentsOf: chunk[0..<min(count, limit + 1 - buffer.count)])
                if buffer.count > limit { overLimit = true }
                return overLimit
            }
            if full { return }
        }
    }
}
