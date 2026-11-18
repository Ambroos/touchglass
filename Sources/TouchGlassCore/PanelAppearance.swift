import Foundation

/// The panel's look.
public enum PanelAppearance: String, Sendable, Equatable, CaseIterable {
    /// Clear glass with dark smoke, HDR white title, glyphs and ring.
    case smoked
    /// Regular glass without smoke, for the most legible text. The default.
    case readable
}

/// Host settings from `host.conf`: one `key = value` per line, `#` starts a comment line.
public struct HostSettings: Sendable, Equatable {
    public var appearance: PanelAppearance = .readable

    public init(appearance: PanelAppearance = .readable) {
        self.appearance = appearance
    }

    /// Parses the file's text. Unknown keys and invalid values are ignored.
    public static func parse(_ text: String) -> HostSettings {
        var settings = HostSettings()
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "appearance":
                if let appearance = PanelAppearance(rawValue: value) { settings.appearance = appearance }
            default:
                continue
            }
        }
        return settings
    }

    /// Reads `path`; a missing or unreadable file gives the defaults.
    public static func load(path: String) -> HostSettings {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return HostSettings() }
        return parse(text)
    }
}
