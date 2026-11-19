import Foundation

/// The TouchGlass release that this process belongs to.
public enum BuildInfo {
    /// `CFBundleShortVersionString` of the `TouchGlass.app` that contains this executable, or nil outside a
    /// bundle, as in `swift build` output. The helpers in `Contents/MacOS` share the app's Info.plist.
    ///
    /// Read once, on first use. A long-running process must read it at startup: Homebrew's `opt` path
    /// shows the next release's Info.plist after `brew upgrade`, while the process still runs the previous
    /// release's code.
    public static let version: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Whether `candidate` is a later release than `current`. Both must be dotted numbers, such as "0.2.0";
    /// anything else, such as Homebrew's "HEAD-1a2b3c4", is never newer, so it never makes a host exit.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return !parts.isEmpty && numbers.count == parts.count && numbers.allSatisfy { $0 >= 0 } ? numbers : nil
    }
}
