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
        let compact = serial.uppercased().filter { !$0.isWhitespace }
        return compact.count == 32 && compact.hasPrefix("D276000124") && compact.dropFirst(16).prefix(4) == "0006"
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
    static let slotNames = ["sign", "decrypt", "auth"]

    public static func parse(_ text: String) -> [CardTouchPolicy] {
        var cards: [String: CardTouchPolicy] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let serial = trimmed[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            guard !serial.isEmpty, serial.count <= 32, serial.allSatisfy(\.isHexDigit) else { continue }
            let words = trimmed[trimmed.index(after: equals)...].split(separator: " ")
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
public struct GnuPGCardPolicyQuery: CardPolicyQuerying {
    /// Where to look for gpg-connect-agent after the proxy's `bin` directory.
    public static let fallbackBinDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/MacGPG2/bin", "/opt/local/bin"]
    public static let timeout: TimeInterval = 10

    private let homeDirectory: String

    public init(homeDirectory: String = IPCPaths.homeDirectory) {
        self.homeDirectory = homeDirectory
    }

    public func arguments(serial: String, gnupg: GnuPGContext) -> [String] {
        ["--no-autostart", "--homedir", gnupg.home ?? homeDirectory + "/.gnupg", "scd serialno --demand=\(serial)", "scd getattr UIF", "/bye"]
    }

    public func executable(gnupg: GnuPGContext) -> String? {
        let directories = [gnupg.binDir].compactMap { $0 } + Self.fallbackBinDirectories
        return directories.map { $0 + "/gpg-connect-agent" }.first { access($0, X_OK) == 0 }
    }

    public func query(serial: String, gnupg: GnuPGContext) -> [Int: TouchPolicy]? {
        // The serial goes into an Assuan command line: only hex digits.
        guard !serial.isEmpty, serial.count <= 32, serial.allSatisfy(\.isHexDigit), let executable = executable(gnupg: gnupg) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(serial: serial, gnupg: gnupg)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { [process] in process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return CardPolicyFile.parseQueryOutput(String(decoding: data, as: UTF8.self), serial: serial)
    }
}
