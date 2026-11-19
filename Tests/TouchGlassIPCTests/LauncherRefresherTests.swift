import Foundation
import Synchronization
import Testing
@testable import TouchGlassIPC

@Suite struct LauncherRefresherTests {
    /// Records what the refresher starts and logs.
    final class Recorder: Sendable {
        let spawns = Mutex<[[String]]>([])
        let events = Mutex<[LogEvent]>([])
        let spawnSucceeds: Bool
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refresher-\(UUID().uuidString)")

        init(spawnSucceeds: Bool = true) {
            self.spawnSucceeds = spawnSucceeds
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func refresher(launcher: String?, copyRelease: String?, helperRelease: String? = "1.2.0", bundledCommand: String? = command) throws -> LauncherRefresher {
            let copy = directory.appendingPathComponent("touchglass-\(UUID().uuidString)").path
            if let copyRelease {
                try "#!/bin/sh\nprog=touchglass\ncli_version=\(copyRelease)\nlauncher_format=1\n".write(toFile: copy, atomically: true, encoding: .utf8)
            }
            return LauncherRefresher(
                environment: launcher.map { [LauncherRefresher.environmentKey: $0] } ?? [:],
                bundledCommand: bundledCommand,
                commandCopy: copy,
                helperRelease: helperRelease,
                spawn: { path, arguments in
                    self.spawns.withLock { $0.append([path] + arguments) }
                    return self.spawnSucceeds
                },
                log: { event in self.events.withLock { $0.append(event) } }
            )
        }

        var spawnCount: Int { spawns.withLock { $0.count } }
        var loggedEvents: [LogEvent] { events.withLock { $0 } }
    }

    static let command = "/opt/homebrew/opt/touchglass/TouchGlass.app/Contents/Resources/touchglass"

    @Test func staleLauncherStartsTheRefreshOnce() throws {
        let recorder = Recorder()
        let refresher = try recorder.refresher(launcher: "0", copyRelease: "1.2.0")
        #expect(refresher.refreshIfNeeded() == .launcherFormat(installed: 0, current: LauncherRefresher.format))
        #expect(refresher.refreshIfNeeded() == nil)
        #expect(recorder.spawns.withLock { $0 } == [[Self.command, "refresh-launchers"]])
        #expect(recorder.loggedEvents == [.launcherRefresh(.launcherFormat(installed: 0, current: 1), started: true)])
    }

    @Test func currentLauncherAndCopyStartNothing() throws {
        let recorder = Recorder()
        let refresher = try recorder.refresher(launcher: "\(LauncherRefresher.format)", copyRelease: "1.2.0")
        #expect(refresher.refreshIfNeeded() == nil)
        #expect(recorder.spawnCount == 0)
        #expect(recorder.loggedEvents.isEmpty)
    }

    @Test func helperNotStartedByALauncherStartsNothing() throws {
        let recorder = Recorder()
        // The copy is out of date too, but without a launcher there may be no install to refresh.
        let refresher = try recorder.refresher(launcher: nil, copyRelease: "0.1.0")
        #expect(refresher.refreshIfNeeded() == nil)
        #expect(recorder.spawnCount == 0)
    }

    @Test func olderCommandCopyStartsTheRefresh() throws {
        let recorder = Recorder()
        let refresher = try recorder.refresher(launcher: "1", copyRelease: "1.1.9")
        #expect(refresher.refreshIfNeeded() == .commandRelease(installed: "1.1.9", helper: "1.2.0"))
        #expect(recorder.spawnCount == 1)
        #expect(recorder.loggedEvents.first?.message == "command copy: release 1.1.9 is older than helper release 1.2.0: started touchglass refresh-launchers")
    }

    @Test func laterFormatOrReleaseIsNeverRefreshed() throws {
        let recorder = Recorder()
        // A later release wrote the launchers: this helper is from a downgrade.
        #expect(try recorder.refresher(launcher: "\(LauncherRefresher.format + 1)", copyRelease: "0.1.0").refreshIfNeeded() == nil)
        #expect(try recorder.refresher(launcher: "1", copyRelease: "1.10.0").refreshIfNeeded() == nil)
        #expect(recorder.spawnCount == 0)
    }

    @Test func releasesThatAreNotNumbersNeverRefreshTheCopy() throws {
        let recorder = Recorder()
        #expect(try recorder.refresher(launcher: "1", copyRelease: "dev").refreshIfNeeded() == nil)
        #expect(try recorder.refresher(launcher: "1", copyRelease: "1.0.0", helperRelease: nil).refreshIfNeeded() == nil)
        #expect(try recorder.refresher(launcher: "1", copyRelease: "1.0.0", helperRelease: "0.0.0-dev").refreshIfNeeded() == nil)
        #expect(try recorder.refresher(launcher: "1", copyRelease: nil).refreshIfNeeded() == nil)
        #expect(recorder.spawnCount == 0)
    }

    @Test func malformedLauncherFormatStartsNothing() throws {
        let recorder = Recorder()
        for value in ["", "x", "-1", "1.0"] {
            #expect(try recorder.refresher(launcher: value, copyRelease: "0.1.0").refreshIfNeeded() == nil)
        }
        #expect(recorder.spawnCount == 0)
    }

    @Test func helperOutsideABundleStartsNothing() throws {
        let recorder = Recorder()
        #expect(try recorder.refresher(launcher: "0", copyRelease: "0.1.0", bundledCommand: nil).refreshIfNeeded() == nil)
        #expect(recorder.spawnCount == 0)
        #expect(recorder.loggedEvents.isEmpty)
    }

    @Test func failedStartIsLogged() throws {
        let recorder = Recorder(spawnSucceeds: false)
        _ = try recorder.refresher(launcher: "0", copyRelease: "1.2.0").refreshIfNeeded()
        #expect(recorder.loggedEvents == [.launcherRefresh(.launcherFormat(installed: 0, current: 1), started: false)])
        #expect(recorder.loggedEvents.first?.message == "launchers: format 0 is older than 1: could not start touchglass refresh-launchers")
    }

    @Test func bundledCommandIsInTheHelpersBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refresher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("TouchGlass.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let helper = app.appendingPathComponent("MacOS/touchglass-pinentry").path
        #expect(LauncherRefresher.bundledCommand(executablePath: helper) == nil)
        let command = app.appendingPathComponent("Resources/touchglass").path
        FileManager.default.createFile(atPath: command, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(LauncherRefresher.bundledCommand(executablePath: helper) == command)
        #expect(LauncherRefresher.bundledCommand(executablePath: "/opt/build/debug/touchglass-pinentry") == nil)
        #expect(LauncherRefresher.bundledCommand(executablePath: nil) == nil)
    }

    @Test func realSpawnRunsTheCommandDetached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refresher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("ran").path
        let command = root.appendingPathComponent("touchglass").path
        // Records its arguments and whether stdout is /dev/null rather than the test's output.
        let script = "#!/bin/sh\nexec 3>&1\nif [ \"$(stat -L -f %r /dev/fd/3)\" = \"$(stat -L -f %r /dev/null)\" ]; then out=null; else out=other; fi\necho \"$* $out\" > '\(marker).tmp'\nmv '\(marker).tmp' '\(marker)'\n"
        FileManager.default.createFile(atPath: command, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        #expect(LauncherRefresher.spawnDetached(command, [LauncherRefresher.command]))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { usleep(10_000) }
        #expect((try? String(contentsOfFile: marker, encoding: .utf8)) == "refresh-launchers null\n")
    }

    /// The helpers and the command must agree on the launcher format, the variable and the release stamp.
    @Test func scriptWritesTheFormatTheHelpersExpect() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/touchglass")
        let text = try String(contentsOf: script, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains("launcher_format=\(LauncherRefresher.format)"))
        #expect(text.contains("\(LauncherRefresher.environmentKey)=$launcher_format; export \(LauncherRefresher.environmentKey)"))
        #expect(text.contains("    \(LauncherRefresher.command)) cmd_refresh_launchers"))
        #expect(LauncherRefresher.release(ofCommandAt: script.path) == "dev")
    }
}
