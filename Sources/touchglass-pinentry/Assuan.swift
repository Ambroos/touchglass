import TouchGlassIPC

// Assuan line helpers for the pinentry side of the protocol. Lines are bytes: arguments can carry raw bytes such as the RS (0x1E) and US (0x1F) separators in card descriptions.

enum Assuan {
    /// gpg-error values as pinentry reports them: source PINENTRY (5) in bits 24-30, error code in the low 16 bits.
    static func pinentryError(_ code: UInt32) -> UInt32 { (5 << 24) | code }

    static let cancelled = "ERR \(pinentryError(99)) Operation cancelled <Pinentry>"
    static let notConfirmed = "ERR \(pinentryError(114)) Not confirmed <Pinentry>"
    static let timeout = "ERR \(pinentryError(62)) Timeout <Pinentry>"
    static let noPinentry = "ERR \(pinentryError(85)) No pinentry <Pinentry>"
    static let parameterError = "ERR \(pinentryError(280)) IPC parameter error <Pinentry>"
    /// libassuan's reply to an unknown command, with source USER_1 (32), as pinentry-mac sends it.
    static let unknownCommand = "ERR \((32 << 24) | 275) Unknown IPC command <User defined source 1>"

    /// The commands that the pinentry knows, which its trace may name.
    static let knownCommands: Set<String> = [
        "BYE", "OPTION", "SETDESC", "SETPROMPT", "SETTITLE", "SETERROR", "SETOK", "SETCANCEL", "SETNOTOK",
        "SETKEYINFO", "SETREPEAT", "SETREPEATERROR", "SETREPEATOK", "SETQUALITYBAR", "SETQUALITYBAR_TT",
        "SETGENPIN", "SETGENPIN_TT", "SETTIMEOUT", "RESET", "GETINFO", "GETPIN", "CONFIRM", "MESSAGE",
        "CLEARPASSPHRASE", "NOP", "CANCEL", "AUTH", "END", "INPUT", "OUTPUT", "HELP",
    ]

    /// The keyword as the trace logs it: a known command by name, anything else as "other", so no text
    /// from the agent's stream reaches the log.
    static func traceKeyword(_ keyword: String) -> String {
        knownCommands.contains(keyword) ? keyword : "other"
    }

    /// Splits a command line into its keyword, upper-cased, and the argument bytes after the separating spaces.
    static func splitCommand(_ line: [UInt8]) -> (keyword: String, arguments: [UInt8]) {
        let end = line.firstIndex(where: { $0 == 0x20 || $0 == 0x09 }) ?? line.endIndex
        let keyword = String(decoding: line[..<end], as: UTF8.self).uppercased()
        var start = end
        while start < line.endIndex, line[start] == 0x20 || line[start] == 0x09 {
            start += 1
        }
        return (keyword, Array(line[start...]))
    }

    /// Decodes every %XX escape. Invalid escapes stay as they are. A plus sign is not decoded, matching pinentry.
    static func percentDecode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// Decodes a percent-escaped argument to text. Invalid UTF-8 becomes U+FFFD.
    static func decodeText(_ bytes: [UInt8]) -> String {
        String(decoding: percentDecode(bytes), as: UTF8.self)
    }

    /// Escapes data for a D line the way libassuan does: only %, CR and LF.
    static func escapeData(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "%"), 0x0D, 0x0A:
                out.append(UInt8(ascii: "%"))
                out.append(contentsOf: hexDigits(byte))
            default:
                out.append(byte)
            }
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func hexDigits(_ byte: UInt8) -> [UInt8] {
        let digits = Array("0123456789ABCDEF".utf8)
        return [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
    }
}

enum CardDescription {
    static let recordSeparator: Character = "\u{1E}"
    static let unitSeparator: Character = "\u{1F}"

    /// Splits a decoded description into display text and card fields.
    ///
    /// With tabbing advertised, scdaemon's card block reads `<RS>Number<US>: 12 345 678\nHolder<US>: \nCounter<US>: 7`. The text keeps every line but drops the RS and US bytes. Fields are matched by their English label, or by position when the labels are translated. Returns nil fields when the description has no RS.
    static func parse(_ description: String) -> (text: String, fields: CardFields?) {
        let text = description.filter { $0 != recordSeparator && $0 != unitSeparator }
        guard let start = description.firstIndex(of: recordSeparator) else {
            return (text, nil)
        }
        var fields = CardFields()
        var position = 0
        for line in description[description.index(after: start)...].split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: unitSeparator) else { break }
            let label = line[..<separator].trimmingSpaces().lowercased()
            var value = line[line.index(after: separator)...]
            if value.first == ":" { value = value.dropFirst() }
            let trimmed = String(value).trimmingSpaces()
            let names = ["number", "holder", "counter"]
            let name = names.contains(label) ? label : (position < names.count ? names[position] : "")
            switch name {
            case "number": fields.number = trimmed
            case "holder": fields.holder = trimmed
            case "counter": fields.counter = trimmed
            default: break
            }
            position += 1
        }
        return (text, fields == CardFields() ? nil : fields)
    }
}

extension StringProtocol {
    func trimmingSpaces() -> String {
        String(drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
    }
}
