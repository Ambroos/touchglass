import Darwin
import Foundation

/// Starts the TouchGlass host app for a helper.
///
/// The helpers ship in `TouchGlass.app/Contents/MacOS`, so each one launches the bundle it lives in. Opening
/// the app by name would let LaunchServices pick any registered copy, such as a stale build with another IPC
/// version.
public enum HostLauncher {
    /// The app name to open when a helper runs outside a bundle, for example from a build directory.
    public static let appName = "TouchGlass"

    /// The `.app` bundle that contains `executable` as `<bundle>/Contents/MacOS/<name>`, or nil.
    public static func bundlePath(containing executable: String) -> String? {
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        let macOS = url.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else {
            return nil
        }
        return bundle.path
    }

    /// What a helper opens by default: its own bundle, or the app by name when it runs outside one.
    public static func defaultTarget(executablePath: String? = Bundle.main.executablePath) -> String {
        let resolved = executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return resolved.flatMap(bundlePath(containing:)) ?? appName
    }

    /// Runs `/usr/bin/open -g` for `target`, an app bundle path or an app name, without activating it.
    /// Returns the PID of `open`, which the caller reaps. Stdio goes to `/dev/null` and no other descriptor
    /// is inherited, so `open` never holds a helper's agent pipes or sockets.
    public static func launch(_ target: String) -> pid_t? {
        let arguments = target.hasPrefix("/") ? ["-g", target] : ["-g", "-a", target]
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Helpers ignore or catch some signals; `open` starts with the defaults.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, sig)
        }
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let path = "/usr/bin/open"
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 ? pid : nil
    }
}
