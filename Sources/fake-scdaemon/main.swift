// A scriptable stand-in for scdaemon, for testing touchglass-scdaemon without a card.
//
// It speaks the Assuan server side on stdin/stdout and, if the config names a socket, on that socket too.
// Behaviour comes from the JSON file named by FAKE_SCD_CONFIG; see `Config` for the keys. Every byte it
// receives and sends is appended to `<record_dir>/scd-<connection>.in` and `.out`, so tests can compare
// both ends of the proxy.
//
// Commands beyond the scdaemon subset, for tests:
//   BLOB          replies with D lines holding every byte value, a long status line with raw high bytes
//                 and NUL, a comment line, then OK.
//   ECHOINQ       sends INQUIRE ECHO, then returns the answered data as D lines.
//   SLEEP <ms>    waits, then OK.
//   EXIT <code>   exits immediately with that code, without a reply.
//
// Of GETATTR it knows only UIF and UIF-<n>, from the config's `uif`.

import Darwin
import Foundation

struct Config: Decodable {
    /// Socket to listen on; GETINFO socket_name returns it. Absent: no socket, empty socket_name.
    var socket: String?
    var record_dir: String?
    var serial: String = "D2760001240100000006123456780000"
    /// Keygrip to OpenPGP slot (1 sig, 2 dec, 3 aut).
    var keys: [String: Int] = [:]
    var pin: String = "123456"
    /// PIN references (1 or 2) that count as verified at start.
    var verified: [Int] = []
    /// Send INQUIRE PINCACHE_GET before NEEDPIN.
    var pincache: Bool = false
    /// Answer to PINCACHE_GET that counts as a cached PIN.
    var pincache_hit: String = "CAFEF00D"
    /// Delay before INQUIRE NEEDPIN, in ms, as when scdaemon waits for the card lock or a slow card.
    var needpin_delay_ms: Int = 0
    /// Delay before the card answers a crypto command when it needs a touch, in ms.
    var touch_ms: Int = 0
    /// After a touch, operations within this window need no touch, in ms (YubiKey "cached" policy). Each
    /// operation restarts the window, as the YubiKey does.
    var touch_cache_ms: Int = 0
    /// Delay before the card answers a crypto command that needs no touch, in ms.
    var cached_ms: Int = 0
    /// Answer the touch with ERR Timeout instead of a result.
    var touch_timeout: Bool = false
    /// Exit code after end of file on stdin.
    var exit_on_eof: Int32 = 0
    /// Delay before exiting after end of file on stdin, writing a comment line first, in ms.
    var eof_linger_ms: Int = 0
    /// Write replies in chunks of 1 to 3 bytes.
    var split_writes: Bool = false
    /// The values of the `S UIF-1` to `S UIF-3` lines for GETATTR and LEARN, as scdaemon escapes them, such
    /// as "%03+". Absent: the card has no button, so GETATTR UIF fails and LEARN sends no UIF lines.
    var uif: [String]?
    /// A second attached card and its UIF values. Each connection has a current card, which SERIALNO
    /// --demand selects and RESTART forgets; without one, a command uses the card that any connection
    /// selected last, as scdaemon does.
    var second_serial: String?
    var second_uif: [String]?

    enum CodingKeys: String, CodingKey {
        case socket, record_dir, serial, keys, pin, verified, pincache, pincache_hit, needpin_delay_ms, touch_ms, touch_cache_ms, cached_ms
        case touch_timeout, exit_on_eof, eof_linger_ms, split_writes, uif, second_serial, second_uif
    }

    var serials: [String] { [serial] + (second_serial.map { [$0] } ?? []) }

    func uif(for card: String) -> [String]? {
        card == second_serial ? second_uif : uif
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        socket = try c.decodeIfPresent(String.self, forKey: .socket)
        record_dir = try c.decodeIfPresent(String.self, forKey: .record_dir)
        serial = try c.decodeIfPresent(String.self, forKey: .serial) ?? serial
        keys = try c.decodeIfPresent([String: Int].self, forKey: .keys) ?? keys
        pin = try c.decodeIfPresent(String.self, forKey: .pin) ?? pin
        verified = try c.decodeIfPresent([Int].self, forKey: .verified) ?? verified
        pincache = try c.decodeIfPresent(Bool.self, forKey: .pincache) ?? pincache
        pincache_hit = try c.decodeIfPresent(String.self, forKey: .pincache_hit) ?? pincache_hit
        needpin_delay_ms = try c.decodeIfPresent(Int.self, forKey: .needpin_delay_ms) ?? needpin_delay_ms
        touch_ms = try c.decodeIfPresent(Int.self, forKey: .touch_ms) ?? touch_ms
        touch_cache_ms = try c.decodeIfPresent(Int.self, forKey: .touch_cache_ms) ?? touch_cache_ms
        cached_ms = try c.decodeIfPresent(Int.self, forKey: .cached_ms) ?? cached_ms
        touch_timeout = try c.decodeIfPresent(Bool.self, forKey: .touch_timeout) ?? touch_timeout
        exit_on_eof = try c.decodeIfPresent(Int32.self, forKey: .exit_on_eof) ?? exit_on_eof
        eof_linger_ms = try c.decodeIfPresent(Int.self, forKey: .eof_linger_ms) ?? eof_linger_ms
        split_writes = try c.decodeIfPresent(Bool.self, forKey: .split_writes) ?? split_writes
        uif = try c.decodeIfPresent([String].self, forKey: .uif)
        second_serial = try c.decodeIfPresent(String.self, forKey: .second_serial)
        second_uif = try c.decodeIfPresent([String].self, forKey: .second_uif)
    }
}

let config: Config = {
    guard let path = ProcessInfo.processInfo.environment["FAKE_SCD_CONFIG"] else { return Config() }
    do {
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        FileHandle.standardError.write(Data("fake-scdaemon: bad config: \(error)\n".utf8))
        exit(3)
    }
}()

/// The signal dispositions this process started with, as `<name>=default|ignore|handler` lines, recorded
/// before it changes any of them.
let startSignals: String = {
    let names: [(String, Int32)] = [("HUP", SIGHUP), ("INT", SIGINT), ("PIPE", SIGPIPE), ("TERM", SIGTERM), ("USR1", SIGUSR1), ("USR2", SIGUSR2)]
    return names.map { name, number in
        var action = sigaction()
        sigaction(number, nil, &action)
        let handler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        let disposition = handler == unsafeBitCast(SIG_DFL, to: Int.self) ? "default" : handler == unsafeBitCast(SIG_IGN, to: Int.self) ? "ignore" : "handler"
        return "\(name)=\(disposition)"
    }.joined(separator: "\n")
}()

signal(SIGPIPE, SIG_IGN)

// MARK: - Card state, shared by all connections like the real card

final class Card: @unchecked Sendable {
    let lock = NSLock()
    var verified: Set<Int>
    var lastTouch: Double = -1e9
    /// The card that a connection selected last.
    var lastSelected = config.serial

    init() { verified = Set(config.verified) }
}
let card = Card()

func now() -> Double { Date().timeIntervalSince1970 }

// MARK: - Recording

if let dir = config.record_dir {
    let env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    let args = CommandLine.arguments.joined(separator: "\n")
    try? Data("ARGS\n\(args)\nENV\n\(env)\nSIGNALS\n\(startSignals)\n".utf8).write(to: URL(fileURLWithPath: dir + "/scd-start.txt"))
}

func record(_ name: String, _ suffix: String, _ bytes: UnsafeRawBufferPointer) {
    guard let dir = config.record_dir, bytes.count > 0 else { return }
    let path = "\(dir)/scd-\(name).\(suffix)"
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { return }
    _ = write(fd, bytes.baseAddress, bytes.count)
    close(fd)
}

// MARK: - Assuan connection

final class Connection {
    let name: String
    let input: Int32
    let output: Int32
    private var buffer: [UInt8] = []
    private var eof = false

    init(name: String, input: Int32, output: Int32) {
        self.name = name
        self.input = input
        self.output = output
    }

    /// The next line without its LF, or nil at end of file.
    func readLine() -> [UInt8]? {
        while true {
            if let lf = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<lf])
                buffer.removeSubrange(...lf)
                return line
            }
            if eof { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                eof = true
                continue
            }
            chunk.withUnsafeBytes { record(name, "in", UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { record(name, "out", $0) }
        if config.split_writes {
            var i = 0
            while i < bytes.count {
                let n = min(bytes.count - i, 1 + i % 3)
                bytes[i..<(i + n)].withUnsafeBytes { _ = write(output, $0.baseAddress, n) }
                i += n
            }
        } else {
            bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(output, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { if errno == EINTR { continue }; return }
                    offset += n
                }
            }
        }
    }

    func send(_ line: String) { send(Array(line.utf8) + [0x0A]) }

    /// Sends payload as D lines, escaping only %, CR and LF like libassuan.
    func sendData(_ payload: [UInt8]) {
        var line: [UInt8] = Array("D ".utf8)
        for byte in payload {
            if byte == 0x25 || byte == 0x0D || byte == 0x0A {
                line += Array(String(format: "%%%02X", byte).utf8)
            } else {
                line.append(byte)
            }
            if line.count >= 998 {
                send(line + [0x0A])
                line = Array("D ".utf8)
            }
        }
        if line.count > 2 { send(line + [0x0A]) }
    }

    /// Sends an inquiry and collects the client's answer. Returns nil if the client sent CAN or closed.
    func inquire(_ text: String) -> [UInt8]? {
        send("INQUIRE " + text)
        var data: [UInt8] = []
        while let line = readLine() {
            if line.starts(with: Array("D ".utf8)) {
                data += unescape(line.dropFirst(2))
            } else if line == Array("END".utf8) {
                return data
            } else if line == Array("CAN".utf8) {
                return nil
            }
        }
        return nil
    }
}

func unescape(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    var i = bytes.startIndex
    while i < bytes.endIndex {
        if bytes[i] == 0x25, i + 2 < bytes.endIndex, let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
            out.append(v)
            i += 3
        } else {
            out.append(bytes[i])
            i += 1
        }
    }
    return out
}

let errCancelled = "ERR 100663573 IPC call has been cancelled <SCD>"
let errBadPin = "ERR 100663383 Bad PIN <SCD>"
let errTimeout = "ERR 100663358 Timeout <SCD>"
let errInvId = "ERR 100663363 Invalid ID <SCD>"
let errUnknown = "ERR 536871187 Unknown IPC command <User defined source 1>"

/// The signature or plaintext the fake card returns: includes NUL, %, CR, LF and high bytes.
let resultBytes: [UInt8] = [0x00, 0x25, 0x0D, 0x0A, 0xFF, 0x80, 0x41, 0x1E, 0x1F] + (0..<55).map { UInt8($0 * 7 & 0xFF) }

func usage(_ slot: Int) -> String { slot == 1 ? "sc" : slot == 2 ? "e" : "sa" }

/// Serves one connection until BYE or end of file. Returns true if it ended with end of file.
func serve(_ conn: Connection, isPipe: Bool) -> Bool {
    /// The card that this connection selected; nil until SERIALNO, and after RESTART.
    var current: String?
    conn.send("OK GNU Privacy Guard's Smartcard server ready, process \(getpid())")
    while let raw = conn.readLine() {
        var lineBytes = raw[...]
        if lineBytes.last == 0x0D { lineBytes = lineBytes.dropLast() }
        if lineBytes.isEmpty || lineBytes.first == UInt8(ascii: "#") { continue }
        let line = String(decoding: lineBytes, as: UTF8.self)
        let words = line.split(separator: " ").map(String.init)
        let command = words[0].uppercased()
        let args = Array(words.dropFirst())

        switch command {
        case "GETINFO":
            switch args.first {
            case "socket_name":
                if let socket = config.socket { conn.send("D " + socket) }
                conn.send("OK")
            case "version": conn.send("D 2.5.24"); conn.send("OK")
            case "pid": conn.send("D \(getpid())"); conn.send("OK")
            case "card_list":
                for serial in config.serials { conn.send("S SERIALNO " + serial) }
                conn.send("OK")
            default: conn.send("ERR 100663427 Invalid value <SCD>")
            }
        case "OPTION", "SETDATA", "NOP":
            conn.send("OK")
        case "RESTART":
            current = nil
            conn.send("OK")
        case "SERIALNO":
            if let demand = args.first(where: { $0.hasPrefix("--demand=") })?.dropFirst("--demand=".count) {
                guard config.serials.contains(String(demand)) else {
                    current = nil
                    conn.send("ERR 100696144 No such device <SCD>")
                    continue
                }
                current = String(demand)
            } else {
                current = card.lock.withLock { card.lastSelected }
            }
            card.lock.withLock { card.lastSelected = current! }
            conn.send("S SERIALNO " + current!)
            conn.send("OK")
        case "GETATTR":
            // Only the touch policy: UIF for all three slots, or UIF-<n> for one.
            let name = args.first?.uppercased() ?? ""
            let slots = name == "UIF" ? [1, 2, 3] : name.hasPrefix("UIF-") ? Int(name.dropFirst(4)).map { [$0] } ?? [] : []
            guard let uif = config.uif(for: current ?? card.lock.withLock({ card.lastSelected })), !slots.isEmpty, slots.allSatisfy({ (1...uif.count).contains($0) }) else {
                conn.send("ERR 100663354 No data <SCD>")
                continue
            }
            for slot in slots { conn.send("S UIF-\(slot) \(uif[slot - 1])") }
            conn.send("OK")
        case "LEARN":
            // A short version of what scdaemon sends for an OpenPGP card with a button.
            conn.send("S READER Fake Reader 00 00")
            let learned = current ?? card.lock.withLock { card.lastSelected }
            conn.send("S SERIALNO " + learned)
            conn.send("S APPTYPE openpgp")
            for (index, value) in (config.uif(for: learned) ?? []).enumerated() { conn.send("S UIF-\(index + 1) \(value)") }
            conn.send("OK")
        case "KEYINFO":
            let wanted: [(String, Int)]
            if args.first?.hasPrefix("--list") == true {
                let auth = args.first == "--list=auth"
                wanted = config.keys.filter { !auth || $0.value == 3 }.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
            } else {
                wanted = args.last.flatMap { grip in config.keys[grip].map { [(grip, $0)] } } ?? []
            }
            for (grip, slot) in wanted {
                conn.send("S KEYINFO \(grip) T \(config.serial) OPENPGP.\(slot) \(usage(slot))")
            }
            conn.send(wanted.isEmpty && args.first?.hasPrefix("--list") != true ? "ERR 100663379 Not found <SCD>" : "OK")
        case "PKSIGN", "PKAUTH", "PKDECRYPT":
            cryptoOperation(conn, command: command, grip: args.last { !$0.hasPrefix("--") } ?? "")
        case "BLOB":
            conn.sendData((0...255).map { UInt8($0) })
            conn.send(Array("S KDF ".utf8) + [0x81, 0xFE, 0x00, 0x03, 0xFF] + Array(repeating: UInt8(ascii: "x"), count: 990) + [0x0A])
            conn.send("# a comment line with 100%25 escapes")
            conn.send("OK")
        case "ECHOINQ":
            guard let data = conn.inquire("ECHO") else { conn.send(errCancelled); continue }
            conn.sendData(data)
            conn.send("OK")
        case "SLEEP":
            usleep(UInt32(Int(args.first ?? "0") ?? 0) * 1000)
            conn.send("OK")
        case "EXIT":
            exit(Int32(args.first ?? "0") ?? 0)
        case "KILLSCD":
            conn.send("OK closing connection")
            exit(0)
        case "BYE":
            conn.send("OK closing connection")
            return false
        default:
            conn.send(errUnknown)
        }
    }
    return true
}

func cryptoOperation(_ conn: Connection, command: String, grip: String) {
    guard let slot = config.keys[grip] else { conn.send(errInvId); return }
    if (command == "PKAUTH" && slot != 3) || (command == "PKDECRYPT" && slot != 2) {
        conn.send(errInvId)
        return
    }
    // The card serves one operation at a time.
    card.lock.lock()
    defer { card.lock.unlock() }

    let pinRef = command == "PKSIGN" && slot == 1 ? 1 : 2
    if !card.verified.contains(pinRef) {
        var cached = false
        if config.pincache {
            guard let answer = conn.inquire("PINCACHE_GET 0/openpgp/\(pinRef)") else { conn.send(errCancelled); return }
            cached = !answer.isEmpty && String(decoding: answer, as: UTF8.self) == config.pincache_hit
        }
        if !cached {
            var prompt = "||Please unlock the card%0A%0A\u{1E}Number\u{1F}: 12 345 678%0AHolder\u{1F}: "
            if pinRef == 1 { prompt += "%0ACounter\u{1F}: 7" }
            usleep(UInt32(config.needpin_delay_ms) * 1000)
            guard let answer = conn.inquire("NEEDPIN " + prompt) else { conn.send(errCancelled); return }
            let pin = answer.prefix { $0 != 0 }
            guard Array(pin) == Array(config.pin.utf8) else { conn.send(errBadPin); return }
            conn.send("S PINCACHE_PUT 0/openpgp/\(pinRef) 00112233445566778899AABBCCDDEEFF")
        }
        card.verified.insert(pinRef)
    }

    if now() - card.lastTouch > Double(config.touch_cache_ms) / 1000 {
        usleep(UInt32(config.touch_ms) * 1000)
        if config.touch_timeout {
            card.verified.remove(pinRef)
            conn.send(errTimeout)
            return
        }
    } else {
        usleep(UInt32(config.cached_ms) * 1000)
    }
    card.lastTouch = now()
    if command == "PKDECRYPT" { conn.send("S PADDING 0") }
    conn.sendData(resultBytes)
    conn.send("OK")
}

// MARK: - Socket server

if let socketPath = config.socket {
    unlink(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
        FileHandle.standardError.write(Data("fake-scdaemon: cannot listen on \(socketPath)\n".utf8))
        exit(3)
    }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    Thread.detachNewThread {
        var count = 0
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            count += 1
            let name = "sock\(count)"
            Thread.detachNewThread {
                _ = serve(Connection(name: name, input: client, output: client), isPipe: false)
                close(client)
            }
        }
    }
}

// MARK: - Pipe server

let endedWithEOF = serve(Connection(name: "pipe", input: STDIN_FILENO, output: STDOUT_FILENO), isPipe: true)
if endedWithEOF && config.eof_linger_ms > 0 {
    Connection(name: "pipe", input: -1, output: STDOUT_FILENO).send("# stdin closed, exiting")
    usleep(UInt32(config.eof_linger_ms) * 1000)
}
if let socketPath = config.socket { unlink(socketPath) }
exit(endedWithEOF ? config.exit_on_eof : 0)
