import Foundation

/// The touch policy of one key slot, from the first byte of the card's User Interaction Flag (UIF) data
/// object. The OpenPGP card specification defines 0 to 2; Yubico adds 3 and 4 for the touch cache.
public enum TouchPolicy: String, Sendable, Equatable, CaseIterable {
    /// No touch.
    case off
    /// A touch for every operation.
    case on
    /// Like `on`, and the policy can't change without deleting the key.
    case fixed
    /// A touch that the card keeps for `TouchTiming.touchCacheWindow` after an operation.
    case cached
    /// Like `cached`, and the policy can't change without deleting the key.
    case cachedFixed = "cached-fixed"

    /// The policy for a UIF byte, or nil for a value that no specification defines.
    public init?(uif: UInt8) {
        switch uif {
        case 0x00: self = .off
        case 0x01: self = .on
        case 0x02: self = .fixed
        case 0x03: self = .cached
        case 0x04: self = .cachedFixed
        default: return nil
        }
    }

    public var uif: UInt8 {
        switch self {
        case .off: 0x00
        case .on: 0x01
        case .fixed: 0x02
        case .cached: 0x03
        case .cachedFixed: 0x04
        }
    }
}

extension OperationKind {
    /// The OpenPGP key slot the operation uses by default: 1 signs, 2 decrypts, 3 authenticates.
    public var cardSlot: Int? {
        switch self {
        case .sign: 1
        case .decrypt: 2
        case .sshLogin: 3
        case .unknown: nil
        }
    }
}

/// The `touch-cache` setting in `host.conf`.
public enum TouchCacheSetting: Sendable, Equatable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    /// The default: follow each card's learned touch policy per slot, and assume the YubiKey's cached
    /// policy for a card or slot whose policy isn't known.
    case auto
    /// The same window for every card and slot, whatever TouchGlass learned. 0 turns the window off.
    case seconds(TimeInterval)

    public init(integerLiteral value: Int) { self = .seconds(TimeInterval(value)) }
    public init(floatLiteral value: Double) { self = .seconds(value) }

    /// The fixed window, or nil for `auto`.
    public var fixedSeconds: TimeInterval? {
        if case .seconds(let seconds) = self { seconds } else { nil }
    }
}

/// How the host treats an inferred touch wait of one operation.
public enum TouchHandling: Sendable, Equatable {
    /// Within this many seconds after the card's last completed operation, hold the touch step back until
    /// `TouchTiming.cachedDetectionThreshold`. Outside it, show the touch step at once.
    case cacheWindow(TimeInterval)
    /// Show the touch step at once: the card asks for a touch on every operation.
    case everyTime
    /// The slot needs no touch, so the card's silence is most likely something else: show the touch step
    /// only after `TouchTiming.offDetectionThreshold`, in case the policy changed since it was learned.
    case noTouch
}

extension TouchTiming {
    /// How to treat a touch wait for a slot with `policy`, nil when unknown. An explicit `touch-cache`
    /// setting wins over the policy. Without one, `off`, `on` and `fixed` count for any card, because the
    /// OpenPGP card specification defines them. An unknown policy gets the cached window, as before
    /// TouchGlass learned policies. `cached` and `cached-fixed` are Yubico's values; on another card they
    /// count as unknown, which gives the same window.
    public static func handling(setting: TouchCacheSetting, policy: TouchPolicy?) -> TouchHandling {
        if let seconds = setting.fixedSeconds {
            return seconds > 0 ? .cacheWindow(seconds) : .everyTime
        }
        switch policy {
        case .on, .fixed: return .everyTime
        case .off: return .noTouch
        case .cached, .cachedFixed, nil: return .cacheWindow(touchCacheWindow)
        }
    }
}
