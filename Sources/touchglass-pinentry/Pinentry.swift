import Darwin
import Foundation
import TouchGlassIPC

let pinentryVersion = "0.1.0"

/// What the agent set up before a GETPIN, CONFIRM or MESSAGE, decoded.
struct Settings {
    var title: String?
    var desc: String?
    var prompt: String?
    var error: String?
    var ok: String?
    var cancel: String?
    var notok: String?
    var keyinfo: String?
    /// SETREPEAT, SETQUALITYBAR or SETGENPIN were sent: a new-passphrase dialog, which the host does not render.
    var needsFullDialog = false
    var timeout: Double = 0
    var owner: String?
    var ttyname: String?
    var ttytype: String?

    /// RESET: clears the request but keeps the session options, like pinentry.
    mutating func reset() {
        let kept = (owner, ttyname, ttytype)
        self = Settings()
        (owner, ttyname, ttytype) = kept
    }
}

/// An Assuan pinentry server on stdin and stdout that shows prompts through the TouchGlass host, and hands them to pinentry-mac when the host can't.
final class PinentryServer {
    let config: Config
    let log: Log
    /// The arguments gpg-agent passed, without argv[0]. Handed on to pinentry-mac.
    let arguments: [String]
    let input = LineInput(fd: 0)
    let output: Int32 = 1
    var signalPipe: Int32 = -1
    var host: IPCConnection?
    var settings = Settings()
    /// Setup commands received so far, replayed to pinentry-mac on a handoff.
    var transcript: [[UInt8]] = []
    var requestCount = 0

    init(config: Config, arguments: [String]) {
        self.config = config
        self.log = Log(path: config.logFile)
        self.arguments = arguments
    }

    var display: String? {
        guard let index = arguments.firstIndex(of: "--display"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: Startup

    func run() -> Never {
        host = connectToHost()
        if host == nil {
            execFallback()
        }
        signalPipe = installSignalPipe()
        if let host {
            try? host.send(.hello(Hello(role: .pinentry)))
        }
        reply("OK Pleased to meet you, process \(getpid())")
        while true {
            guard let line = waitForCommand() else { exit(0) }
            handle(line)
        }
    }

    /// Connects to the host, launching it if needed, within the configured timeouts.
    func connectToHost() -> IPCConnection? {
        if let connection = try? IPCClient.connect(path: config.socketPath, timeout: config.connectTimeout) {
            log("connected to host")
            return connection
        }
        guard let app = config.hostApp else {
            log("host not reachable; launching disabled")
            return nil
        }
        log("host not reachable; launching \(app)")
        let opener = spawn("/usr/bin/open", ["-g", "-a", app], stdin: nil, stdout: nil, stderr: nil)
        let deadline = now() + config.launchTimeout
        defer {
            if let opener {
                var status: Int32 = 0
                waitpid(opener, &status, WNOHANG)
            }
        }
        while now() < deadline {
            if let connection = try? IPCClient.connect(path: config.socketPath, timeout: config.connectTimeout) {
                log("connected to host after launch")
                return connection
            }
            usleep(50_000)
        }
        log("host did not come up")
        return nil
    }

    /// Replaces this process with pinentry-mac. Nothing has been read from or written to stdio yet, so pinentry-mac talks to the agent directly. Returns only if the exec fails.
    func execFallback() {
        log("exec \(config.fallbackPinentry)")
        let argv = ([config.fallbackPinentry] + arguments).map { strdup($0) } + [nil]
        execv(config.fallbackPinentry, argv)
        log("exec failed: errno \(errno); serving without host or fallback")
    }

    // MARK: Command loop

    /// Waits for the next command line. Returns nil when the agent closes stdin or a terminating signal arrives.
    func waitForCommand() -> [UInt8]? {
        while true {
            if let line = input.nextLine() { return line }
            if input.reachedEOF { return nil }
            var fds = [input.fd, signalPipe]
            if let host { fds.append(host.fileDescriptor) }
            let ready = waitReadable(fds, timeout: nil)
            if ready.contains(signalPipe), !drainSignals(signalPipe).isEmpty {
                log("signal while idle")
                return nil
            }
            if let host, ready.contains(host.fileDescriptor) {
                // Nothing is outstanding; drain stray messages and notice a closed host early.
                if (try? host.readAvailable()) == nil { dropHost("closed while idle") }
            }
            if ready.contains(input.fd) {
                input.fill()
            }
        }
    }

    func handle(_ line: [UInt8]) {
        if line.isEmpty || line.first == UInt8(ascii: "#") { return }
        let (keyword, arguments) = Assuan.splitCommand(line)
        let text = Assuan.decodeText(arguments)
        log("<- \(keyword)")

        switch keyword {
        case "BYE":
            reply("OK closing connection")
            exit(0)
        case "OPTION":
            setOption(String(decoding: arguments, as: UTF8.self))
        case "SETDESC": settings.desc = text
        case "SETPROMPT": settings.prompt = text
        case "SETTITLE": settings.title = text
        case "SETERROR": settings.error = text
        case "SETOK": settings.ok = text
        case "SETCANCEL": settings.cancel = text
        case "SETNOTOK": settings.notok = text
        case "SETKEYINFO": settings.keyinfo = (text == "--clear" || text.isEmpty) ? nil : text
        case "SETREPEAT", "SETQUALITYBAR", "SETGENPIN": settings.needsFullDialog = true
        case "SETREPEATERROR", "SETREPEATOK", "SETQUALITYBAR_TT", "SETGENPIN_TT": break
        case "SETTIMEOUT": settings.timeout = Double(text.trimmingSpaces()) ?? 0
        case "RESET": settings.reset()
        case "GETINFO":
            getInfo(text.trimmingSpaces())
            return
        case "GETPIN", "CONFIRM", "MESSAGE":
            request(keyword, arguments: text, line: line)
            return
        case "CLEARPASSPHRASE", "NOP", "CANCEL", "AUTH", "END", "INPUT", "OUTPUT":
            reply("OK")
            return
        case "HELP":
            for name in ["BYE", "OPTION", "SETDESC", "SETPROMPT", "SETTITLE", "SETERROR", "SETOK", "SETCANCEL", "SETNOTOK", "SETKEYINFO", "SETREPEAT", "SETREPEATERROR", "SETREPEATOK", "SETQUALITYBAR", "SETQUALITYBAR_TT", "SETGENPIN", "SETGENPIN_TT", "SETTIMEOUT", "RESET", "GETINFO", "GETPIN", "CONFIRM", "MESSAGE", "CLEARPASSPHRASE"] {
                reply("# \(name)")
            }
            reply("OK")
            return
        default:
            reply(Assuan.unknownCommand)
            return
        }
        transcript.append(line)
        reply("OK")
    }

    /// OPTION always succeeds. Records the values the host or GETINFO use.
    func setOption(_ option: String) {
        let separator = option.firstIndex(where: { $0 == "=" || $0 == " " })
        let name = separator.map { String(option[..<$0]) } ?? option
        let value = separator.map { String(option[option.index(after: $0)...]).trimmingSpaces() }
        switch name.trimmingSpaces().lowercased() {
        case "owner": settings.owner = value
        case "ttyname": settings.ttyname = value
        case "ttytype": settings.ttytype = value
        default: break
        }
    }

    func getInfo(_ what: String) {
        switch what {
        case "flavor":
            // Advertising tabbing makes the agent keep the RS/US separators in card descriptions.
            reply("S FEATURES tabbing")
            reply("D touchglass")
        case "version":
            reply("D \(pinentryVersion)")
        case "pid":
            // Our own PID: the agent stops a popup message by signalling this process.
            reply("D \(getpid())")
        case "ttyinfo":
            let tty = settings.ttyname ?? "-"
            let type = settings.ttytype ?? "-"
            reply("D \(tty) \(type) \(display ?? "-") - \(geteuid())/\(getegid()) -")
        default:
            reply(Assuan.parameterError)
            return
        }
        reply("OK")
    }

    // MARK: Requests

    func request(_ keyword: String, arguments: String, line: [UInt8]) {
        if keyword == "GETPIN", settings.needsFullDialog {
            log("new-passphrase dialog; handing off")
            handoff(line)
            return
        }
        guard host != nil else {
            handoff(line)
            return
        }

        requestCount += 1
        let id = "\(getpid())-\(requestCount)"
        let message: IPCMessage
        switch keyword {
        case "GETPIN":
            let (text, fields) = CardDescription.parse(settings.desc ?? "")
            message = .getPin(GetPin(id: id, title: settings.title, desc: settings.desc == nil ? nil : text, prompt: settings.prompt, fields: fields, error: settings.error, ok: settings.ok, cancel: settings.cancel, keyinfo: settings.keyinfo, owner: settings.owner))
        case "CONFIRM":
            let oneButton = arguments.split(separator: " ").contains("--one-button")
            message = .confirm(Confirm(id: id, title: settings.title, desc: settings.desc.map { CardDescription.parse($0).text }, ok: settings.ok, cancel: oneButton ? nil : settings.cancel, notok: oneButton ? nil : settings.notok, oneButton: oneButton, owner: settings.owner))
        default:
            message = .message(MessageRequest(id: id, title: settings.title, desc: settings.desc.map { CardDescription.parse($0).text }, ok: settings.ok))
        }

        let outcome = exchange(message, id: id)
        // pinentry shows a SETERROR text once.
        settings.error = nil

        switch outcome {
        case .reply(.pin(let pin)) where keyword == "GETPIN":
            log("-> D [redacted]")
            writeAll(output, Array("D ".utf8) + Assuan.escapeData(pin.secret) + [0x0A])
            reply("OK")
        case .reply(.confirmed) where keyword != "GETPIN":
            reply("OK")
        case .reply(.notConfirmed) where keyword == "CONFIRM":
            reply(Assuan.notConfirmed)
        case .reply:
            reply(Assuan.cancelled)
        case .timedOut:
            reply(Assuan.timeout)
        case .fallback(let reason):
            log("falling back: \(reason)")
            handoff(line)
        }
    }

    enum Outcome {
        case reply(IPCMessage)
        case timedOut
        case fallback(String)
    }

    /// Sends a request to the host and waits for its answer, while watching stdin for EOF, signals, SETTIMEOUT, and host health.
    func exchange(_ message: IPCMessage, id: String) -> Outcome {
        guard let host else { return .fallback("no host") }
        log("-> host \(message.type) \(id)")
        do {
            try host.send(message)
        } catch {
            dropHost("send failed")
            return .fallback("host send failed")
        }

        let start = now()
        var lastHeard = start
        var nextPing = start + config.pingInterval
        var seq = 0
        let deadline = settings.timeout > 0 ? start + settings.timeout : nil

        while true {
            let t = now()
            if let deadline, t >= deadline {
                dismiss(id)
                return .timedOut
            }
            if t - lastHeard >= config.hostStallTimeout {
                dismiss(id)
                dropHost("stalled")
                return .fallback("host stopped responding")
            }
            if t >= nextPing {
                seq += 1
                try? host.send(.ping(Ping(seq: seq)))
                nextPing = t + config.pingInterval
            }

            let wake = [Optional(nextPing), Optional(lastHeard + config.hostStallTimeout), deadline].compactMap { $0 }.min()!
            var fds = [signalPipe, host.fileDescriptor]
            if !input.reachedEOF { fds.append(input.fd) }
            let ready = waitReadable(fds, timeout: wake - now())

            if ready.contains(signalPipe), !drainSignals(signalPipe).isEmpty {
                log("signal during request")
                dismiss(id)
                exit(0)
            }
            if ready.contains(input.fd), !input.fill() {
                log("agent closed stdin during request")
                dismiss(id)
                exit(0)
            }
            if ready.contains(host.fileDescriptor) {
                let messages: [IPCMessage]
                do {
                    messages = try host.readAvailable()
                } catch {
                    dropHost("closed during request")
                    return .fallback("host closed the connection")
                }
                lastHeard = now()
                for reply in messages where reply.requestID == id {
                    log("<- host \(reply.type) \(id)")
                    switch reply {
                    case .pin, .confirmed, .notConfirmed, .cancelled:
                        return .reply(reply)
                    case .fallback:
                        return .fallback("host asked")
                    default:
                        continue
                    }
                }
            }
        }
    }

    func dismiss(_ id: String) {
        log("-> host dismiss \(id)")
        try? host?.send(.dismiss(RequestRef(id: id)))
    }

    func dropHost(_ reason: String) {
        log("host dropped: \(reason)")
        host?.close()
        host = nil
    }

    // MARK: Output

    func reply(_ line: String) {
        log("-> \(line.hasPrefix("D ") ? "D …" : line)")
        if !writeAll(output, Array(line.utf8) + [0x0A]) {
            exit(0)
        }
    }
}
