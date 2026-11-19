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
    /// The longest `touch-timeout` the host accepts, in seconds.
    public static let maximumTouchTimeout: TimeInterval = 600

    public var appearance: PanelAppearance = .readable
    /// Show what asked for a card operation, such as "git commit · touchglass".
    public var showClient = true
    /// Overrides the touch countdown length that the scdaemon proxy reports, in seconds.
    public var touchTimeout: TimeInterval?
    /// How long a touch stays cached on the card: `auto` follows each card's learned touch policy, a number of
    /// seconds applies to every card. See `TouchTiming.handling(setting:policy:)`.
    public var touchCache: TouchCacheSetting = .auto

    public init(appearance: PanelAppearance = .readable, showClient: Bool = true, touchTimeout: TimeInterval? = nil, touchCache: TouchCacheSetting = .auto) {
        self.appearance = appearance
        self.showClient = showClient
        self.touchTimeout = touchTimeout
        self.touchCache = touchCache
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
            case "show-client":
                switch value.lowercased() {
                case "yes": settings.showClient = true
                case "no": settings.showClient = false
                default: continue
                }
            case "touch-timeout":
                if let seconds = Double(value), seconds >= 1, seconds <= maximumTouchTimeout { settings.touchTimeout = seconds }
            case "touch-cache":
                if value.lowercased() == "auto" {
                    settings.touchCache = .auto
                } else if let seconds = Double(value), seconds >= 0, seconds <= maximumTouchTimeout {
                    settings.touchCache = .seconds(seconds)
                }
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
