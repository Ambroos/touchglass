/// Which way an Assuan stream flows through the proxy.
public enum StreamDirection: Sendable {
    /// From gpg-agent to scdaemon: commands and inquiry answers.
    case toServer
    /// From scdaemon to gpg-agent: responses.
    case toClient
}

/// One Assuan line, reduced to what the operation detector needs.
///
/// The tap never keeps the payload of `D` lines, inquiry text or arguments of commands it does not need,
/// so PINs, signatures and decrypted data never reach this type.
public enum WireLine: Sendable, Equatable {
    /// A client command. `args` is filled only for commands in `AssuanTap.commandsWithArgs`.
    case command(keyword: String, args: [String])
    /// A `D` line in either direction. The payload is dropped.
    case data
    /// `END` from the client, ending an inquiry answer.
    case end
    /// `CAN` from the client, cancelling an inquiry.
    case cancel
    /// A server status line. `args` is filled only for keywords in `AssuanTap.statusWithArgs`.
    case status(keyword: String, args: [String])
    case ok
    /// `ERR` with the numeric gpg-error code, if one parses.
    case err(code: Int?)
    /// A server inquiry. `args` is filled only for keywords in `AssuanTap.inquiriesWithArgs`.
    case inquire(keyword: String, args: [String])
    case comment
    /// Anything else, including lines too long for the tap's buffer.
    case other
}

/// Splits a byte stream into Assuan lines and classifies them, without changing or holding up the stream.
///
/// The caller feeds every chunk it forwards, in order. The tap buffers at most `maxLineLength` bytes of one
/// line and never buffers the payload of a `D` line: it recognizes `D ` at the start of a line and skips
/// to the next line feed.
public struct AssuanTap: Sendable {
    public static let commandsWithArgs: Set<String> = ["PKSIGN", "PKAUTH", "PKDECRYPT", "GETINFO"]
    public static let statusWithArgs: Set<String> = ["KEYINFO"]
    public static let inquiriesWithArgs: Set<String> = ["POPUPPINPADPROMPT"]

    /// Longer than any legal Assuan line (1000 bytes plus CR and LF).
    public static let maxLineLength = 1100

    private enum Mode: Sendable {
        case accumulating
        case skippingData
        case overflow
    }

    public let direction: StreamDirection
    private var mode: Mode = .accumulating
    private var buffer: [UInt8] = []

    public init(direction: StreamDirection) {
        self.direction = direction
        buffer.reserveCapacity(128)
    }

    /// Feeds forwarded bytes and returns the lines completed by them.
    public mutating func feed(_ bytes: UnsafeRawBufferPointer) -> [WireLine] {
        var lines: [WireLine] = []
        var i = 0
        let count = bytes.count
        while i < count {
            switch mode {
            case .skippingData, .overflow:
                // Jump to the next line feed without looking at the bytes in between.
                var j = i
                while j < count && bytes[j] != 0x0A { j += 1 }
                if j == count { return lines }
                lines.append(mode == .skippingData ? .data : .other)
                mode = .accumulating
                i = j + 1
            case .accumulating:
                let byte = bytes[i]
                i += 1
                if byte == 0x0A {
                    if let line = classify(buffer) { lines.append(line) }
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
                buffer.append(byte)
                if buffer.count == 2 && buffer[0] == UInt8(ascii: "D") && buffer[1] == UInt8(ascii: " ") {
                    buffer.removeAll(keepingCapacity: true)
                    mode = .skippingData
                } else if buffer.count > Self.maxLineLength {
                    buffer.removeAll(keepingCapacity: true)
                    mode = .overflow
                }
            }
        }
        return lines
    }

    public mutating func feed(_ bytes: [UInt8]) -> [WireLine] {
        bytes.withUnsafeBytes { feed($0) }
    }

    private func classify(_ raw: [UInt8]) -> WireLine? {
        var line = raw[...]
        if line.last == 0x0D { line = line.dropLast() }
        if line.isEmpty { return nil }
        if line.first == UInt8(ascii: "#") { return .comment }
        let keywordEnd = line.firstIndex(of: 0x20) ?? line.endIndex
        let keyword = String(decoding: line[line.startIndex..<keywordEnd], as: UTF8.self).uppercased()
        let rest = keywordEnd < line.endIndex ? line[(keywordEnd + 1)...] : []

        if keyword == "D" { return .data }
        switch direction {
        case .toServer:
            switch keyword {
            case "END": return .end
            case "CAN": return .cancel
            default:
                let args = Self.commandsWithArgs.contains(keyword) ? Self.words(rest) : []
                return .command(keyword: keyword, args: args)
            }
        case .toClient:
            switch keyword {
            case "OK": return .ok
            case "ERR":
                let words = Self.words(rest)
                return .err(code: words.first.flatMap { Int($0) })
            case "S":
                var words = Self.words(rest)
                guard !words.isEmpty else { return .other }
                let status = words.removeFirst().uppercased()
                return .status(keyword: status, args: Self.statusWithArgs.contains(status) ? words : [])
            case "INQUIRE":
                var words = Self.words(rest)
                guard !words.isEmpty else { return .other }
                let name = words.removeFirst().uppercased()
                return .inquire(keyword: name, args: Self.inquiriesWithArgs.contains(name) ? words : [])
            default:
                return .other
            }
        }
    }

    private static func words(_ bytes: ArraySlice<UInt8>) -> [String] {
        bytes.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    }
}
