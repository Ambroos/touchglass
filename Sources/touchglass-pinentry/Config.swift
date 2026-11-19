import Foundation
import TouchGlassIPC

/// Settings for touchglass-pinentry.
///
/// gpg-agent starts the pinentry with its own environment, which is hard to change under launchd, so settings come from a file: `~/Library/Application Support/TouchGlass/pinentry.conf`, one `key = value` per line, `#` for comments. Environment variables override the file; tests use them.
///
/// | Key | Environment | Default |
/// |---|---|---|
/// | `fallback-pinentry` | `TOUCHGLASS_FALLBACK_PINENTRY` | the first executable of `defaultFallbacks`; also used when the file names a pinentry that isn't executable |
/// | `host-app` | `TOUCHGLASS_HOST_APP` | the `TouchGlass.app` that contains this executable, else the app named `TouchGlass`; an absolute path opens that bundle; `none` disables launching |
/// | `connect-timeout-ms` | `TOUCHGLASS_CONNECT_TIMEOUT_MS` | 300 |
/// | `launch-timeout-ms` | `TOUCHGLASS_LAUNCH_TIMEOUT_MS` | 2000 |
/// | `ping-interval-ms` | `TOUCHGLASS_PING_INTERVAL_MS` | 1000 |
/// | `host-stall-ms` | `TOUCHGLASS_HOST_STALL_MS` | 3000 |
/// | `log-file` | `TOUCHGLASS_PINENTRY_LOG` | none |
///
/// `TOUCHGLASS_SOCKET` sets the host socket path and `TOUCHGLASS_CONFIG` the config file path.
struct Config {
    var fallbackPinentry: String
    var hostApp: String?
    var socketPath: String
    var connectTimeout: TimeInterval
    var launchTimeout: TimeInterval
    var pingInterval: TimeInterval
    var hostStallTimeout: TimeInterval
    var logFile: String?

    /// pinentry-mac, then Homebrew's pinentry, which GnuPG depends on: `brew uninstall touchglass` can
    /// remove pinentry-mac with it. The pinentry launcher tries the same list.
    static let defaultFallbacks = ["/opt/homebrew/bin/pinentry-mac", "/usr/local/bin/pinentry-mac", "/opt/homebrew/bin/pinentry", "/usr/local/bin/pinentry"]

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> Config {
        let configPath = environment["TOUCHGLASS_CONFIG"] ?? IPCPaths.supportDirectory + "/pinentry.conf"
        let file = (try? String(contentsOfFile: configPath, encoding: .utf8)).map(parse) ?? [:]

        func value(_ key: String, _ variable: String) -> String? {
            if let v = environment[variable], !v.isEmpty { return v }
            return file[key]
        }
        func seconds(_ key: String, _ variable: String, _ defaultMs: Double) -> TimeInterval {
            (value(key, variable).flatMap(Double.init) ?? defaultMs) / 1000
        }

        // The environment variable is exact, for tests; the file's value counts while it is executable.
        let executable = { (path: String) in FileManager.default.isExecutableFile(atPath: path) }
        let fromFile = file["fallback-pinentry"].flatMap { $0.isEmpty ? nil : $0 }
        let fallback = environment["TOUCHGLASS_FALLBACK_PINENTRY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? fromFile.flatMap { executable($0) ? $0 : nil }
            ?? defaultFallbacks.first(where: executable)
            ?? fromFile
            ?? defaultFallbacks[0]
        let app = value("host-app", "TOUCHGLASS_HOST_APP") ?? HostLauncher.defaultTarget()

        return Config(
            fallbackPinentry: fallback,
            hostApp: app == "none" ? nil : app,
            socketPath: environment["TOUCHGLASS_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? IPCPaths.supportDirectory + "/host.sock",
            connectTimeout: seconds("connect-timeout-ms", "TOUCHGLASS_CONNECT_TIMEOUT_MS", 300),
            launchTimeout: seconds("launch-timeout-ms", "TOUCHGLASS_LAUNCH_TIMEOUT_MS", 2000),
            pingInterval: seconds("ping-interval-ms", "TOUCHGLASS_PING_INTERVAL_MS", 1000),
            hostStallTimeout: seconds("host-stall-ms", "TOUCHGLASS_HOST_STALL_MS", 3000),
            logFile: value("log-file", "TOUCHGLASS_PINENTRY_LOG")
        )
    }

    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}

/// Appends diagnostic lines to the configured log file. Callers must never pass secrets: the PIN is logged only as "[redacted]".
struct Log {
    private let handle: FileHandle?

    init(path: String?) {
        guard let path else {
            handle = nil
            return
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
    }

    func callAsFunction(_ message: @autoclosure () -> String) {
        guard let handle else { return }
        let line = "touchglass-pinentry[\(getpid())]: \(message())\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
