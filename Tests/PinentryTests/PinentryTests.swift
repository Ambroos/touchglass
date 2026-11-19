import Darwin
import Foundation
import Testing
import TouchGlassIPC
@testable import touchglass_pinentry

@Suite struct AssuanHelperTests {
    @Test func percentDecoding() {
        #expect(Assuan.decodeText(Array("a%0Ab%25c+d%zz%4".utf8)) == "a\nb%c+d%zz%4")
        #expect(Assuan.percentDecode(Array("%1e%1F".utf8)) == [0x1E, 0x1F])
    }

    @Test func dataEscaping() {
        #expect(Assuan.escapeData(Array("12%34\r\n5 +".utf8)) == Array("12%2534%0D%0A5 +".utf8))
        #expect(Assuan.escapeData([0x00, 0xFF]) == [0x00, 0xFF])
    }

    @Test func commandSplitting() {
        let (keyword, arguments) = Assuan.splitCommand(Array("confirm   --one-button".utf8))
        #expect(keyword == "CONFIRM")
        #expect(arguments == Array("--one-button".utf8))
        #expect(Assuan.splitCommand(Array("BYE".utf8)).arguments.isEmpty)
    }

    @Test func cardDescriptionForSigning() {
        let desc = "Please unlock the card\n\n\u{1E}Number\u{1F}: 12 345 678\nHolder\u{1F}: \nCounter\u{1F}: 42"
        let (text, fields) = CardDescription.parse(desc)
        #expect(text == "Please unlock the card\n\nNumber: 12 345 678\nHolder: \nCounter: 42")
        #expect(fields == CardFields(number: "12 345 678", holder: "", counter: "42"))
    }

    @Test func cardDescriptionForAuthWithRemainingAttempts() {
        let desc = "Please unlock the card\n\n\u{1E}Number\u{1F}: 12 345 678\nHolder\u{1F}: Test Holder\n\nRemaining attempts: 2"
        let (_, fields) = CardDescription.parse(desc)
        #expect(fields == CardFields(number: "12 345 678", holder: "Test Holder", counter: nil))
    }

    @Test func translatedLabelsMapByPosition() {
        let desc = "Karte entsperren\n\n\u{1E}Nummer\u{1F}: 1\nInhaber\u{1F}: X\nZähler\u{1F}: 3"
        #expect(CardDescription.parse(desc).fields == CardFields(number: "1", holder: "X", counter: "3"))
    }

    @Test func descriptionWithoutSeparatorsHasNoFields() {
        #expect(CardDescription.parse("Enter passphrase").fields == nil)
    }

    @Test func configFileParsing() {
        let parsed = Config.parse("# comment\nfallback-pinentry = /opt/x/pinentry-mac\n\nhost-app=none\n")
        #expect(parsed == ["fallback-pinentry": "/opt/x/pinentry-mac", "host-app": "none"])
    }
}

@Suite struct ConfigTests {
    /// A fallback in pinentry.conf counts while it is executable; after that, the defaults take over.
    @Test func fallbackFromTheFileMustBeExecutable() throws {
        let sandbox = Sandbox()
        let path = sandbox.directory + "/pinentry.conf"
        try "fallback-pinentry = /bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(Config.load(environment: ["TOUCHGLASS_CONFIG": path]).fallbackPinentry == "/bin/sh")

        let missing = sandbox.directory + "/gone/pinentry-mac"
        try "fallback-pinentry = \(missing)\n".write(toFile: path, atomically: true, encoding: .utf8)
        let installed = Config.defaultFallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }
        #expect(Config.load(environment: ["TOUCHGLASS_CONFIG": path]).fallbackPinentry == installed ?? missing)

        // The environment variable is taken as it is.
        #expect(Config.load(environment: ["TOUCHGLASS_CONFIG": path, "TOUCHGLASS_FALLBACK_PINENTRY": missing]).fallbackPinentry == missing)
    }
}

/// Answers every request like a user who types `secret` and presses OK.
func answering(secret: String) -> @Sendable (IPCMessage) -> IPCMessage? {
    { message in
        switch message {
        case .getPin(let r): .pin(PinReply(id: r.id, secret: Data(secret.utf8)))
        case .confirm(let r): .confirmed(RequestRef(id: r.id))
        case .message(let r): .confirmed(RequestRef(id: r.id))
        default: nil
        }
    }
}

@Suite struct WithHostTests {
    @Test func cardPinRequest() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath, answer: answering(secret: "12%34\n56"))
        let pinentry = try PinentryDriver(sandbox: sandbox, arguments: ["--display", ":0"])

        #expect(pinentry.handshake() == "OK Pleased to meet you, process \(pinentry.pid)")
        #expect(pinentry.transact("GETINFO flavor") == ["S FEATURES tabbing", "D touchglass", "OK"])
        // Outside TouchGlass.app, the build has no release version.
        #expect(pinentry.transact("GETINFO version") == ["D 0.0.0", "OK"])
        #expect(pinentry.transact("GETINFO ttyinfo") == ["D /dev/ttys009 xterm-256color :0 - \(geteuid())/\(getegid()) -", "OK"])
        #expect(pinentry.transact("GETINFO pid") == ["D \(pinentry.pid)", "OK"])
        #expect(pinentry.transact("SETKEYINFO --clear") == ["OK"])
        pinentry.sendBytes(cardSetDesc)
        #expect(pinentry.readResponse() == ["OK"])
        #expect(pinentry.transact("SETPROMPT PIN") == ["OK"])

        pinentry.send("GETPIN")
        #expect(pinentry.readLineBytes() == Array("D 12%2534%0A56".utf8))
        #expect(pinentry.readLine() == "OK")

        let request = host.received.compactMap { if case .getPin(let r) = $0 { r } else { nil } }.first
        #expect(request?.desc == "Please unlock the card\n\nNumber: 12 345 678\nHolder: Test Holder\nCounter: 42")
        #expect(request?.fields == CardFields(number: "12 345 678", holder: "Test Holder", counter: "42"))
        #expect(request?.prompt == "PIN")
        #expect(request?.keyinfo == nil)
        #expect(request?.owner == "4242/501 testhost")
        #expect(host.received.first == .hello(Hello(role: .pinentry, pid: pinentry.pid, build: nil)))

        #expect(pinentry.transact("BYE") == ["OK closing connection"])
        #expect(pinentry.waitForExit() == 0)
    }

    @Test func cancel() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath) { message in
            if case .getPin(let r) = message { return .cancelled(RequestRef(id: r.id)) }
            return nil
        }
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.handshake()
        #expect(pinentry.transact("GETPIN") == ["ERR 83886179 Operation cancelled <Pinentry>"])
        _ = host
    }

    @Test func confirmVariants() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath) { message in
            guard case .confirm(let r) = message else { return nil }
            switch r.desc {
            case "yes": return .confirmed(RequestRef(id: r.id))
            case "no": return .notConfirmed(RequestRef(id: r.id))
            default: return .cancelled(RequestRef(id: r.id))
            }
        }
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.handshake()

        #expect(pinentry.transact("SETDESC yes") == ["OK"])
        #expect(pinentry.transact("SETOK Allow") == ["OK"])
        #expect(pinentry.transact("SETNOTOK Deny") == ["OK"])
        #expect(pinentry.transact("CONFIRM") == ["OK"])
        #expect(pinentry.transact("SETDESC no") == ["OK"])
        #expect(pinentry.transact("CONFIRM") == ["ERR 83886194 Not confirmed <Pinentry>"])
        #expect(pinentry.transact("SETDESC other") == ["OK"])
        // pinentry answers OK for a one-button dialog however it closes.
        #expect(pinentry.transact("CONFIRM --one-button") == ["OK"])
        #expect(pinentry.transact("CONFIRM") == ["ERR 83886179 Operation cancelled <Pinentry>"])

        let confirms = host.received.compactMap { if case .confirm(let r) = $0 { r } else { nil } }
        #expect(confirms.count == 4)
        #expect(confirms.first?.ok == "Allow")
        #expect(confirms.first?.notok == "Deny")
        #expect(confirms.first?.oneButton == false)
        #expect(confirms[2].oneButton == true)
        #expect(confirms[2].notok == nil)
        #expect(confirms.last?.oneButton == false)
    }

    @Test func message() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath, answer: answering(secret: ""))
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.handshake()
        #expect(pinentry.transact("SETDESC Push ACK button on card/token.") == ["OK"])
        #expect(pinentry.transact("MESSAGE") == ["OK"])
        let message = host.received.compactMap { if case .message(let r) = $0 { r } else { nil } }.first
        #expect(message?.desc == "Push ACK button on card/token.")
    }

    @Test func dismissedMessageIsOK() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath) { message in
            if case .message(let r) = message { return .cancelled(RequestRef(id: r.id)) }
            return nil
        }
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.handshake()
        #expect(pinentry.transact("MESSAGE") == ["OK"])
        _ = host
    }

    @Test func optionsAndUnknownCommands() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath, answer: answering(secret: ""))
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.readLine()
        #expect(pinentry.transact("OPTION no-such-option=1") == ["OK"])
        #expect(pinentry.transact("OPTION constraints-enforce") == ["OK"])
        #expect(pinentry.transact("FROBNICATE") == ["ERR 536871187 Unknown IPC command <User defined source 1>"])
        #expect(pinentry.transact("GETINFO nonsense") == ["ERR 83886360 IPC parameter error <Pinentry>"])
        #expect(pinentry.transact("NOP") == ["OK"])
        #expect(pinentry.transact("RESET") == ["OK"])
        #expect(pinentry.transact("SETTITLE A%20title") == ["OK"])
        #expect(pinentry.transact("SETQUALITYBAR_TT tip") == ["OK"])
        _ = host
    }

    @Test func seterrorIsSentOnce() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath, answer: answering(secret: "x"))
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.readLine()
        #expect(pinentry.transact("SETERROR Bad Passphrase (try 2 of 3)") == ["OK"])
        #expect(pinentry.transact("GETPIN").last == "OK")
        #expect(pinentry.transact("GETPIN").last == "OK")
        let errors = host.received.compactMap { if case .getPin(let r) = $0 { r.error } else { nil } }
        #expect(errors == ["Bad Passphrase (try 2 of 3)"])
    }

    @Test(arguments: [SIGTERM, SIGINT])
    func signalDismissesAndExits(signal: Int32) throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath) { _ in nil }
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.readLine()
        #expect(pinentry.transact("SETDESC Push ACK") == ["OK"])
        pinentry.send("CONFIRM --one-button")
        let request = host.waitFor { if case .confirm = $0 { true } else { false } }
        #expect(request != nil)

        let sent = Date()
        kill(pinentry.pid, signal)
        #expect(pinentry.waitForExit(timeout: 2) == 0)
        #expect(Date().timeIntervalSince(sent) < 1)
        #expect(host.waitFor { $0 == .dismiss(RequestRef(id: request!.requestID!)) } != nil)
    }

    @Test func agentEOFDuringRequestDismisses() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath) { _ in nil }
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.readLine()
        pinentry.send("GETPIN")
        let request = host.waitFor { if case .getPin = $0 { true } else { false } }
        pinentry.closeInput()
        #expect(pinentry.waitForExit(timeout: 2) == 0)
        #expect(host.waitFor { $0 == .dismiss(RequestRef(id: request!.requestID!)) } != nil)
    }

    @Test func settimeoutRepliesTimeout() throws {
        let sandbox = Sandbox()
        // Answers pings but never the request.
        let host = try FakeHost(path: sandbox.socketPath) { _ in nil }
        let pinentry = try PinentryDriver(sandbox: sandbox, environment: ["TOUCHGLASS_PING_INTERVAL_MS": "100"])
        _ = pinentry.readLine()
        #expect(pinentry.transact("SETTIMEOUT 1") == ["OK"])
        let start = Date()
        #expect(pinentry.transact("GETPIN") == ["ERR 83886142 Timeout <Pinentry>"])
        #expect(Date().timeIntervalSince(start) >= 0.9)
        #expect(host.waitFor { if case .dismiss = $0 { true } else { false } } != nil)
        #expect(host.received.contains { if case .ping = $0 { true } else { false } })
    }

    @Test func pinNeverAppearsInLogs() throws {
        let sandbox = Sandbox()
        let secret = "735190"
        let host = try FakeHost(path: sandbox.socketPath, answer: answering(secret: secret))
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.handshake()
        pinentry.sendBytes(cardSetDesc)
        _ = pinentry.readResponse()
        #expect(pinentry.transact("GETPIN") == ["D \(secret)", "OK"])
        #expect(pinentry.transact("BYE") == ["OK closing connection"])
        #expect(pinentry.waitForExit() == 0)
        _ = host

        let log = sandbox.read(sandbox.pinentryLog)
        #expect(log.contains("GETPIN"))
        #expect(log.contains("[redacted]"))
        let base64 = Data(secret.utf8).base64EncodedString()
        for text in [log, sandbox.read(sandbox.stderrPath)] {
            #expect(!text.contains(secret))
            #expect(!text.contains(base64))
        }
    }
}

@Suite struct FallbackTests {
    @Test func execsFallbackWhenHostIsDown() throws {
        let sandbox = Sandbox()
        let pinentry = try PinentryDriver(sandbox: sandbox, arguments: ["--display", ":0"])
        #expect(pinentry.readLine() == "OK stub ready")
        #expect(pinentry.transact("GETINFO flavor") == ["D stub", "OK"])
        #expect(pinentry.transact("GETPIN") == ["D stub-secret", "OK"])
        #expect(pinentry.transact("BYE") == ["OK closing connection"])
        #expect(pinentry.waitForExit() == 0)
        #expect(sandbox.read(sandbox.stubLog).hasPrefix("ARGS --display :0\n"))
    }

    /// `open` fails for a missing app, so the pinentry falls back without waiting out the launch timeout.
    @Test(arguments: ["TouchGlass Test App That Does Not Exist", "/nonexistent/TouchGlass Test.app"])
    func failedLaunchFallsBackAtOnce(app: String) throws {
        let sandbox = Sandbox()
        let start = Date()
        let pinentry = try PinentryDriver(sandbox: sandbox, environment: ["TOUCHGLASS_HOST_APP": app, "TOUCHGLASS_LAUNCH_TIMEOUT_MS": "20000"])
        #expect(pinentry.readLine(timeout: 25) == "OK stub ready")
        #expect(Date().timeIntervalSince(start) < 10)
        let log = sandbox.read(sandbox.pinentryLog)
        #expect(log.contains("launching \(app)"))
        #expect(log.contains("open exited with status"))
    }

    @Test func missingFallbackStillAnswers() throws {
        let sandbox = Sandbox()
        let pinentry = try PinentryDriver(sandbox: sandbox, environment: ["TOUCHGLASS_FALLBACK_PINENTRY": sandbox.directory + "/missing"])
        #expect(pinentry.readLine()?.hasPrefix("OK Pleased to meet you") == true)
        #expect(pinentry.transact("GETPIN") == ["ERR 83886165 No pinentry <Pinentry>"])
        #expect(pinentry.transact("BYE") == ["OK closing connection"])
    }

    /// Drives a session up to GETPIN with a host that misbehaves, and checks pinentry-mac took over with the replayed setup.
    func expectHandoff(environment: [String: String] = [:], setup: [String] = [], respond: @escaping @Sendable (IPCMessage) -> HostAction) throws -> (Sandbox, FakeHost) {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath, respond: respond)
        let pinentry = try PinentryDriver(sandbox: sandbox, environment: environment)
        _ = pinentry.handshake()
        #expect(pinentry.transact("GETINFO flavor").last == "OK")
        #expect(pinentry.transact("SETDESC Unlock%0Athe card") == ["OK"])
        for command in setup {
            #expect(pinentry.transact(command) == ["OK"])
        }
        #expect(pinentry.transact("GETPIN", timeout: 10) == ["D stub-secret", "OK"])
        #expect(pinentry.transact("BYE") == ["OK closing connection"])
        #expect(pinentry.waitForExit() == 0)

        let lines = sandbox.stubLines
        #expect(lines.contains("OPTION owner=4242/501 testhost"))
        #expect(lines.contains("SETDESC Unlock%0Athe card"))
        #expect(!lines.contains { $0.hasPrefix("GETINFO") })
        #expect(lines.suffix(2) == ["GETPIN", "BYE"])
        return (sandbox, host)
    }

    /// The host closes before it answers anything, so the pinentry reconnects once, then falls back.
    @Test func hostDiesMidRequest() throws {
        let (_, host) = try expectHandoff { message in
            if case .getPin = message { return .close }
            if case .ping(let p) = message { return .send(.pong(p)) }
            return .silent
        }
        #expect(host.received.filter { if case .getPin = $0 { true } else { false } }.count == 2)
    }

    /// A host that exits while the pinentry waits for the agent, such as one that retired for a later
    /// release, is not a reason to fall back: the pinentry connects again for its next request.
    @Test func hostExitsWhileIdleThenTheNextHostAnswers() throws {
        let sandbox = Sandbox()
        let first = try FakeHost(path: sandbox.socketPath, answer: { _ in nil })
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.handshake()
        #expect(first.waitFor { if case .hello = $0 { true } else { false } } != nil)
        first.stop()
        usleep(300_000)
        let second = try FakeHost(path: sandbox.socketPath, answer: answering(secret: "4321"))

        #expect(pinentry.transact("GETPIN", timeout: 10) == ["D 4321", "OK"])
        #expect(pinentry.transact("BYE") == ["OK closing connection"])
        #expect(pinentry.waitForExit() == 0)
        #expect(sandbox.stubLines.isEmpty)
        #expect(second.received.first == .hello(Hello(role: .pinentry, pid: pinentry.pid, build: nil)))
        #expect(sandbox.read(sandbox.pinentryLog).contains("reconnecting to host"))
    }

    @Test func hostStallsMidRequest() throws {
        let start = Date()
        let (_, host) = try expectHandoff(environment: ["TOUCHGLASS_PING_INTERVAL_MS": "100", "TOUCHGLASS_HOST_STALL_MS": "400"]) { _ in .silent }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(host.waitFor { if case .dismiss = $0 { true } else { false } } != nil)
    }

    @Test func hostAsksForFallback() throws {
        _ = try expectHandoff { message in
            if case .getPin(let r) = message { return .send(.fallback(RequestRef(id: r.id))) }
            return .silent
        }
    }

    @Test func newPassphraseDialogGoesStraightToFallback() throws {
        let (_, host) = try expectHandoff(setup: ["SETREPEAT Repeat:", "SETQUALITYBAR Quality:"]) { message in
            if case .ping(let p) = message { return .send(.pong(p)) }
            return .silent
        }
        #expect(!host.received.contains { if case .getPin = $0 { true } else { false } })
    }

    @Test func signalIsForwardedToFallbackChild() throws {
        let sandbox = Sandbox()
        let host = try FakeHost(path: sandbox.socketPath) { message in
            if case .confirm(let r) = message { return .send(.fallback(RequestRef(id: r.id))) }
            return .silent
        }
        let pinentry = try PinentryDriver(sandbox: sandbox)
        _ = pinentry.readLine()
        // The stub execs a long sleep on CONFIRM.
        pinentry.send("CONFIRM --one-button")
        let deadline = Date().addingTimeInterval(5)
        while !sandbox.stubLines.contains("CONFIRM --one-button"), Date() < deadline {
            usleep(20_000)
        }
        kill(pinentry.pid, SIGTERM)
        #expect(pinentry.waitForExit(timeout: 2) == 128 + SIGTERM)
        _ = host
    }
}
