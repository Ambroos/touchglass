import Darwin
import Foundation
import TouchGlassIPC

/// Where the proxy finds the real scdaemon and where it puts its own socket.
public struct ProxyConfig: Sendable {
    /// Overrides the path of the real scdaemon.
    public static let scdaemonEnvironmentKey = "TOUCHGLASS_SCDAEMON_PROGRAM"
    /// Overrides the directory for the proxy's relay socket.
    public static let runtimeDirectoryEnvironmentKey = "TOUCHGLASS_RUNTIME_DIR"
    /// Overrides the touch-wait detection delay, in milliseconds.
    public static let touchDelayEnvironmentKey = "TOUCHGLASS_TOUCH_DELAY_MS"
    /// The host app to start when the host is not running: a bundle path, an app name, or `none`.
    public static let hostAppEnvironmentKey = "TOUCHGLASS_HOST_APP"
    /// File in the support directory whose first line is the path of the real scdaemon. The installer
    /// writes it from `gpgconf --list-components`.
    public static let scdaemonPathFileName = "scdaemon-program"

    /// Where common GnuPG distributions install scdaemon, tried in order when nothing else is configured.
    public static let fallbackScdaemonPaths = [
        "/opt/homebrew/libexec/scdaemon",
        "/usr/local/libexec/scdaemon",
        "/usr/local/MacGPG2/libexec/scdaemon",
        "/opt/local/libexec/scdaemon",
    ]

    public var scdaemonPath: String
    public var runtimeDirectory: String?
    public var hostSocketPath: String
    public var touchDelay: TimeInterval
    /// The app that `HostLauncher` opens when the host is down, or nil to never start it.
    public var hostApp: String?

    /// Resolves the configuration from the environment, the support directory and the fallback paths.
    /// Returns nil if no executable scdaemon other than this program is found.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProxyConfig? {
        var candidates: [String] = []
        if let path = environment[scdaemonEnvironmentKey], !path.isEmpty { candidates.append(path) }
        let pathFile = IPCPaths.supportDirectory + "/" + scdaemonPathFileName
        if let contents = try? String(contentsOfFile: pathFile, encoding: .utf8),
           let line = contents.split(whereSeparator: \.isNewline).first {
            candidates.append(line.trimmingCharacters(in: .whitespaces))
        }
        candidates += fallbackScdaemonPaths

        let ownPath = Bundle.main.executablePath.flatMap(realPath)
        guard let scdaemon = candidates.first(where: { path in
            access(path, X_OK) == 0 && realPath(path) != ownPath
        }) else { return nil }

        let delayMs = environment[touchDelayEnvironmentKey].flatMap { Double($0) } ?? 400
        let hostApp = environment[hostAppEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 } ?? HostLauncher.defaultTarget()
        return ProxyConfig(
            scdaemonPath: scdaemon,
            runtimeDirectory: environment[runtimeDirectoryEnvironmentKey] ?? defaultRuntimeDirectory(),
            hostSocketPath: IPCPaths.hostSocket,
            touchDelay: delayMs / 1000,
            hostApp: hostApp == "none" ? nil : hostApp
        )
    }

    /// `<per-user temporary directory>/touchglass`. The per-user temporary directory is private to the user
    /// and its path has no spaces, `%`, CR or LF.
    static func defaultRuntimeDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        var dir = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if !dir.hasSuffix("/") { dir += "/" }
        return dir + "touchglass"
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
