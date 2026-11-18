import Foundation

/// Newline-delimited JSON framing: one message per line, terminated by LF.
public enum IPCLine {
    /// The longest line a reader accepts, in bytes, without its LF.
    public static let maxLineLength = 64 * 1024

    /// Encodes a message as one line of JSON, including the trailing LF. JSONEncoder escapes control characters inside strings, so the output never contains a raw LF before the terminator.
    public static func encode(_ message: IPCMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    /// Decodes one line, without its LF.
    public static func decode(_ line: Data) throws -> IPCMessage {
        try JSONDecoder().decode(IPCMessage.self, from: line)
    }
}

public enum IPCError: Error, Equatable, Sendable {
    /// The peer closed the connection.
    case closed
    case lineTooLong
    case socketPathTooLong
    /// The socket or its directory is not owned by this user, or the directory is readable by others.
    case insecurePath(String)
    case timedOut
    /// The socket path is in use by a live server.
    case addressInUse
    case system(String, Int32)

    static func errno(_ call: String) -> IPCError {
        .system(call, Darwin.errno)
    }
}

/// Splits a byte stream into lines and decodes each as a message.
public struct IPCLineReader: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends bytes and returns every complete message. Lines that fail to decode are skipped, so a malformed message from a newer peer does not end the connection.
    public mutating func append(_ bytes: Data) throws -> [IPCMessage] {
        buffer.append(bytes)
        var messages: [IPCMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.isEmpty { continue }
            if let message = try? IPCLine.decode(Data(line)) {
                messages.append(message)
            }
        }
        if buffer.count > IPCLine.maxLineLength {
            buffer.removeAll()
            throw IPCError.lineTooLong
        }
        return messages
    }
}
