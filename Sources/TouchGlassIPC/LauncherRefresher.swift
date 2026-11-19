import Darwin
import Foundation
import Synchronization

/// Why a helper started `touchglass refresh-launchers`. Releases are dotted numbers: only those pass
/// `BuildInfo.isNewer`.
public enum LauncherRefreshReason: Sendable, Equatable {
    /// The launcher that started the helper has an older format than the launchers this release writes.
    case launcherFormat(installed: Int, current: Int)
    /// The copy of the command next to the launchers is from an earlier release than the helper.
    case commandRelease(installed: String, helper: String)
}

/// Brings the launchers and the copy of the command in the support directory up to this release.
///
/// Homebrew upgrades the app, but its `post_install` can't write to `~/Library`, so the files that
/// `touchglass install` wrote there stay as the earlier release wrote them. A helper that a launcher
/// started knows the launcher's format from `TOUCHGLASS_LAUNCHER`. If that format is older than
/// `format`, or the command copy is from an earlier release than the helper, the helper starts the
/// `touchglass` command in its own bundle with `refresh-launchers`, and doesn't wait for it. The
/// command replaces each file by rename, so helpers that refresh at once, and a gpg-agent that runs a
/// launcher meanwhile, see whole files. A launcher of a later format, as after a downgrade, is left alone.
public final class LauncherRefresher: Sendable {
    /// The variable that the launchers set, to their format, for the helper they run.
    public static let environmentKey = "TOUCHGLASS_LAUNCHER"
    /// The launcher format that this release's `touchglass` command writes. Must equal `launcher_format`
    /// in `scripts/touchglass`; a test checks it.
    public static let format = 1
    /// The subcommand that rewrites the launchers and the command copy.
    public static let command = "refresh-launchers"

    /// Starts the command with the arguments and doesn't wait for it. Returns whether it started.
    public typealias Spawner = @Sendable (_ path: String, _ arguments: [String]) -> Bool

    let environment: [String: String]
    let bundledCommand: String?
    let commandCopy: String
    let helperRelease: String?
    let spawn: Spawner
    let log: @Sendable (LogEvent) -> Void
    private let checked = Mutex(false)

    /// - Parameters:
    ///   - bundledCommand: the `touchglass` command in the helper's bundle, or nil outside a bundle.
    ///   - commandCopy: the copy of the command next to the launchers.
    ///   - helperRelease: the helper's release, `BuildInfo.version`.
    public init(
        environment: [String: String],
        bundledCommand: String?,
        commandCopy: String,
        helperRelease: String?,
        spawn: @escaping Spawner,
        log: @escaping @Sendable (LogEvent) -> Void
    ) {
        self.environment = environment
        self.bundledCommand = bundledCommand
        self.commandCopy = commandCopy
        self.helperRelease = helperRelease
        self.spawn = spawn
        self.log = log
    }

    /// The refresher for this helper process, logging under `category`.
    public static func forThisProcess(category: LogCategory) -> LauncherRefresher {
        LauncherRefresher(
            environment: ProcessInfo.processInfo.environment,
            bundledCommand: bundledCommand(executablePath: Bundle.main.executablePath),
            commandCopy: IPCPaths.supportDirectory + "/bin/touchglass",
            helperRelease: BuildInfo.version,
            spawn: spawnDetached,
            log: { TouchGlassLog(category)($0) }
        )
    }

    /// Checks once per refresher whether the launchers or the command copy are out of date, and if so,
    /// starts the refresh. Returns why it started one, or nil. Never blocks on the refresh and never fails
    /// the helper.
    @discardableResult
    public func refreshIfNeeded() -> LauncherRefreshReason? {
        let first = checked.withLock { done in
            defer { done = true }
            return !done
        }
        guard first, let launcher = environment[Self.environmentKey] else { return nil }
        let copyRelease = needsCopyRelease(launcher) ? Self.release(ofCommandAt: commandCopy) : nil
        guard let reason = Self.reason(launcherFormat: launcher, commandCopyRelease: copyRelease, helperRelease: helperRelease),
              let bundledCommand else { return nil }
        let started = spawn(bundledCommand, [Self.command])
        log(.launcherRefresh(reason, started: started))
        return reason
    }

    /// Reads the command copy only when the launcher format alone doesn't decide.
    private func needsCopyRelease(_ launcher: String) -> Bool {
        Int(launcher) == Self.format
    }

    /// What the helper refreshes for: `launcherFormat` is the value of `TOUCHGLASS_LAUNCHER`, nil when
    /// no launcher started the helper.
    public static func reason(launcherFormat: String?, commandCopyRelease: String?, helperRelease: String?) -> LauncherRefreshReason? {
        guard let launcherFormat, let installed = Int(launcherFormat), installed >= 0 else { return nil }
        if installed < format { return .launcherFormat(installed: installed, current: format) }
        // A later format: a later release wrote the launchers and the copy. Leave both.
        guard installed == format else { return nil }
        if let commandCopyRelease, let helperRelease, BuildInfo.isNewer(helperRelease, than: commandCopyRelease) {
            return .commandRelease(installed: commandCopyRelease, helper: helperRelease)
        }
        return nil
    }

    /// The release that a copy of the command came from: the value of its `cli_version=` line, which
    /// `scripts/build-app.sh` sets. Nil if the file is missing or has no such line.
    public static func release(ofCommandAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // The line is near the top; the whole script is tens of kilobytes.
        guard let data = try? handle.read(upToCount: 8192) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("cli_version=") {
            return String(line.dropFirst("cli_version=".count))
        }
        return nil
    }

    /// `<bundle>/Contents/Resources/touchglass` for a helper in a bundle, if it is executable. The bundle
    /// comes from the path the helper was started with, as in `HostLauncher.defaultTarget`.
    public static func bundledCommand(executablePath: String?) -> String? {
        guard let executablePath, let bundle = HostLauncher.bundlePath(containing: executablePath) else { return nil }
        let command = bundle + "/Contents/Resources/touchglass"
        return access(command, X_OK) == 0 ? command : nil
    }

    /// Starts the command detached and reaps it on a background thread, so it leaves no zombie.
    static let spawnDetached: Spawner = { path, arguments in
        guard let pid = DetachedProcess.spawn(path, arguments: arguments) else { return false }
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        return true
    }
}
