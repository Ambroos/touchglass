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
    ///
    /// The bundle comes from the path the helper was started with, before symlinks are resolved. The launchers
    /// run the helpers through Homebrew's `opt` link, which survives `brew upgrade`; resolving it gives the
    /// versioned `Cellar` path, which the upgrade deletes while a long-running helper still holds it. Only
    /// when that path isn't inside a bundle, such as a symlink to the helper itself, does the resolved path
    /// count.
    public static func defaultTarget(executablePath: String? = Bundle.main.executablePath) -> String {
        guard let executablePath else { return appName }
        if let bundle = bundlePath(containing: executablePath) { return bundle }
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        return bundlePath(containing: resolved) ?? appName
    }

    /// Runs `/usr/bin/open -g` for `target`, an app bundle path or an app name, without activating it.
    /// Returns the PID of `open`, which the caller reaps. See `DetachedProcess.spawn` for what `open` inherits.
    public static func launch(_ target: String) -> pid_t? {
        let arguments = target.hasPrefix("/") ? ["-g", target] : ["-g", "-a", target]
        return DetachedProcess.spawn("/usr/bin/open", arguments: arguments)
    }
}
