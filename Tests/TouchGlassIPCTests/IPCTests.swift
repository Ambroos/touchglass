import Foundation
import Testing
@testable import TouchGlassIPC

@Suite struct CardSerialTests {
    @Test func acceptsOnlyAsciiHex() {
        #expect(CardSerial.isValid("D2760001240103040006123456780000"))
        #expect(CardSerial.isValid("abc123"))
        #expect(!CardSerial.isValid(""))
        #expect(!CardSerial.isValid(String(repeating: "A", count: 33)))
        #expect(!CardSerial.isValid("D276\nOK"))
        #expect(!CardSerial.isValid("D276 0001"))
        // Fullwidth digits count as hex digits for Character, not here.
        #expect(!CardSerial.isValid("D27600012401030400061234567800\u{FF10}\u{FF10}"))
        #expect(CardSerial.isOpenPGP("D2760001240103040006123456780000"))
        #expect(!CardSerial.isOpenPGP("D2760001240103040006123456780000FF"))
        #expect(!CardSerial.isOpenPGP("A2760001240103040006123456780000"))
    }
}

@Suite struct UIFValueTests {
    @Test func decodesScdaemonEscapes() {
        #expect(UIFValue.firstByte("%03+") == 0x03)
        #expect(UIFValue.firstByte("%00+") == 0x00)
        #expect(UIFValue.firstByte("%04") == 0x04)
        #expect(UIFValue.firstByte("%0a+") == 0x0A)
        #expect(UIFValue.firstByte("%2B+") == 0x2B)
        // A space is escaped as +, other printable bytes are themselves.
        #expect(UIFValue.firstByte("+") == 0x20)
        #expect(UIFValue.firstByte("A+") == 0x41)
    }

    @Test func rejectsMalformedValues() {
        #expect(UIFValue.firstByte("") == nil)
        #expect(UIFValue.firstByte("%") == nil)
        #expect(UIFValue.firstByte("%0") == nil)
        #expect(UIFValue.firstByte("%G3+") == nil)
        #expect(UIFValue.firstByte("%-1") == nil)
        #expect(UIFValue.firstByte("%+1") == nil)
        #expect(UIFValue.firstByte("\u{e9}") == nil)
        #expect(UIFValue.firstByte("\u{1}") == nil)
    }

    @Test func wireFormat() throws {
        let line = try IPCLine.encode(.touchPolicy(TouchPolicyReport(serial: "D276", slot: 1, uif: 3)))
        let json = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(json["type"] as? String == "touch_policy")
        #expect(json["serial"] as? String == "D276" && json["slot"] as? Int == 1 && json["uif"] as? Int == 3)
        let hello = try IPCLine.encode(.hello(Hello(role: .proxy, pid: 1, build: nil, gnupg: GnuPGContext(home: "/h"))))
        let gnupg = try #require((try JSONSerialization.jsonObject(with: hello.dropLast()) as? [String: Any])?["gnupg"] as? [String: String])
        #expect(gnupg == ["home": "/h"])
        // A peer's program location is not part of the message.
        let decoded = try IPCLine.decode(Data(#"{"type":"hello","role":"proxy","pid":1,"version":"1","gnupg":{"home":"/h","bin_dir":"/evil"}}"#.utf8))
        #expect(decoded == .hello(Hello(role: .proxy, pid: 1, version: "1", build: nil, gnupg: GnuPGContext(home: "/h"))))
        #expect(GnuPGContext(home: "relative").isUsable == false)
        #expect(GnuPGContext(home: nil).isUsable && GnuPGContext(home: "/abs").isUsable)
    }

    @Test func logShowsTheLastFourDigits() {
        let event = LogEvent.touchPolicySeen(conn: "12:p", serial: "D2760001240100000006123456780000", slot: 1, uif: 3)
        #expect(event.message == "12:p touch policy: card …5678 slot 1 UIF 03")
        #expect(LogEvent.touchPolicyLearned(serial: "12345678", policies: "sign cached").message == "touch policy: card …5678 sign cached")
        #expect(!LogEvent.touchPolicyQuery(serial: "D2760001240100000006123456780000").message.contains("1234"))
    }
}

@Suite struct MessageCodingTests {
    func roundTrip(_ message: IPCMessage) throws -> IPCMessage {
        let line = try IPCLine.encode(message)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        return try IPCLine.decode(line.dropLast())
    }

    @Test func everyMessageRoundTrips() throws {
        let messages: [IPCMessage] = [
            .hello(Hello(role: .proxy, pid: 42, version: "1", build: nil)),
            .hello(Hello(role: .pinentry, pid: 43, version: "1", build: "0.2.0")),
            .hello(Hello(role: .proxy, pid: 44, version: "1", build: nil, gnupg: GnuPGContext(home: "/tmp/g h"))),
            .hello(Hello(role: .proxy, pid: 45, version: "1", build: nil, gnupg: GnuPGContext())),
            .opStart(OpStart(conn: "123:s3", op: .sign, slot: 1, serial: "D2760001240100000000000000000000", at: 1_800_000_000.5)),
            .opStart(OpStart(conn: "123:p", op: .auth, at: 1, agentPid: 4321)),
            .pinNeeded(ConnRef(conn: "123:p0")),
            .pinSent(ConnRef(conn: "123:p0")),
            .touchWait(TouchWait(conn: "123:p0", timeoutMs: 15_000, at: 1.25)),
            .touchWait(TouchWait(conn: "123:p0", timeoutMs: 15_000, at: 1.25, pinpad: true)),
            .touchPolicy(TouchPolicyReport(serial: "D2760001240100000006123456780000", slot: 2, uif: 3)),
            .touchPolicy(TouchPolicyReport(serial: "D2760001240100000006123456780000", slot: 1, uif: nil)),
            .opEnd(OpEnd(conn: "123:p0", result: .badPin, code: 100_663_383)),
            .getPin(GetPin(id: "1", title: "T", desc: "line1\nline2", prompt: "PIN", fields: CardFields(number: "12 345 678", holder: "", counter: "7"), error: "bad", ok: "OK", cancel: "Cancel", keyinfo: nil, owner: "77/501 host")),
            .confirm(Confirm(id: "2", desc: "Sure?", ok: "Yes", cancel: "No", notok: "Never", oneButton: true)),
            .message(MessageRequest(id: "3", desc: "Hello")),
            .dismiss(RequestRef(id: "1")),
            .ping(Ping(seq: 9)),
            .pin(PinReply(id: "1", secret: Data("12%34\n56".utf8))),
            .confirmed(RequestRef(id: "2")),
            .notConfirmed(RequestRef(id: "2")),
            .cancelled(RequestRef(id: "2")),
            .fallback(RequestRef(id: "2")),
            .pong(Ping(seq: 9)),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message)
        }
    }

    /// Helpers from before the build field send hello without it.
    @Test func helloWithoutBuildDecodes() throws {
        let message = try IPCLine.decode(Data(#"{"type":"hello","role":"proxy","pid":7,"version":"1"}"#.utf8))
        #expect(message == .hello(Hello(role: .proxy, pid: 7, version: "1", build: nil)))
    }

    @Test func wireFieldsAreSnakeCase() throws {
        let touch = String(decoding: try IPCLine.encode(.touchWait(TouchWait(conn: "c", timeoutMs: 15000))), as: UTF8.self)
        #expect(touch == #"{"conn":"c","timeout_ms":15000,"type":"touch_wait"}"# + "\n")

        let confirm = String(decoding: try IPCLine.encode(.confirm(Confirm(id: "1", oneButton: true))), as: UTF8.self)
        #expect(confirm.contains(#""one_button":true"#))
        #expect(confirm.contains(#""type":"confirm""#))

        let pin = String(decoding: try IPCLine.encode(.pin(PinReply(id: "1", secret: Data("1234".utf8)))), as: UTF8.self)
        #expect(pin == #"{"id":"1","secret_b64":"MTIzNA==","type":"pin"}"# + "\n")

        let end = String(decoding: try IPCLine.encode(.opEnd(OpEnd(conn: "c", result: .badPin))), as: UTF8.self)
        #expect(end.contains(#""result":"bad_pin""#))
    }

    @Test func opStartAgentPIDIsOptional() throws {
        let start = String(decoding: try IPCLine.encode(.opStart(OpStart(conn: "c", op: .sign, agentPid: 77))), as: UTF8.self)
        #expect(start.contains(#""agent_pid":77"#))
        // A proxy from before the field existed.
        let old = try IPCLine.decode(Data(#"{"type":"op_start","conn":"c","op":"sign","slot":1}"#.utf8))
        #expect(old == .opStart(OpStart(conn: "c", op: .sign, slot: 1)))
    }

    @Test func unknownTypeDecodesAsUnknown() throws {
        let message = try IPCLine.decode(Data(#"{"type":"future_thing","x":1}"#.utf8))
        #expect(message == .unknown(type: "future_thing"))
    }

    @Test func pinReplyDescriptionHidesSecret() {
        let reply = IPCMessage.pin(PinReply(id: "1", secret: Data("987654".utf8)))
        for text in [String(describing: reply), String(reflecting: reply), "\(reply)"] {
            #expect(!text.contains("987654"))
            #expect(!text.contains("OTg3NjU0"))
        }
        var dumped = ""
        dump(reply, to: &dumped)
        #expect(!dumped.contains("987654"))
    }

    @Test func readerSplitsAndSkipsGarbage() throws {
        var reader = IPCLineReader()
        let a = try IPCLine.encode(.ping(Ping(seq: 1)))
        let b = try IPCLine.encode(.pong(Ping(seq: 2)))
        var stream = a + Data("not json\n\n".utf8) + b
        let tail = stream.suffix(5)
        stream.removeLast(5)
        #expect(try reader.append(stream) == [.ping(Ping(seq: 1))])
        #expect(try reader.append(tail) == [.pong(Ping(seq: 2))])
    }

    @Test func readerRejectsOverlongLine() {
        var reader = IPCLineReader()
        #expect(throws: IPCError.lineTooLong) {
            try reader.append(Data(repeating: 0x41, count: IPCLine.maxLineLength + 1))
        }
    }
}

@Suite struct SocketTests {
    func temporarySocketPath() -> String {
        // sockaddr_un holds 104 bytes, so keep the path short.
        let directory = "/tmp/tg-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        return directory + "/host.sock"
    }

    @Test func clientAndServerExchangeMessages() throws {
        let path = temporarySocketPath()
        let server = try IPCServer(path: path)
        defer { server.close() }

        var info = stat()
        stat((path as NSString).deletingLastPathComponent, &info)
        #expect(info.st_mode & 0o777 == 0o700)

        let client = try IPCClient.connect(path: path)
        let accepted = try server.accept()
        #expect(accepted.peerUID == getuid())
        #expect(accepted.peerPID == getpid())

        try client.send(.getPin(GetPin(id: "1", desc: "Unlock")))
        #expect(try accepted.receive(timeout: 1) == .getPin(GetPin(id: "1", desc: "Unlock")))
        try accepted.send(.cancelled(RequestRef(id: "1")))
        #expect(try client.receive(timeout: 1) == .cancelled(RequestRef(id: "1")))
        #expect(try client.receive(timeout: 0.05) == nil)

        accepted.close()
        #expect(throws: IPCError.closed) { try client.receive(timeout: 1) }
    }

    @Test func connectFailsWhenNoServer() {
        let path = temporarySocketPath()
        #expect(throws: (any Error).self) { try IPCClient.connect(path: path, verifyOwnership: false) }
    }

    @Test func connectRefusesWorldReadableDirectory() throws {
        let path = temporarySocketPath()
        let server = try IPCServer(path: path)
        defer { server.close() }
        let directory = (path as NSString).deletingLastPathComponent
        chmod(directory, 0o755)
        #expect(throws: IPCError.insecurePath(directory)) { try IPCClient.connect(path: path) }
    }

    @Test func serverReplacesStaleSocketButNotLiveOne() throws {
        let path = temporarySocketPath()
        let first = try IPCServer(path: path)
        #expect(throws: IPCError.addressInUse) { try IPCServer(path: path) }
        first.close()

        // Bind and close a socket without unlinking it, leaving a stale socket file behind.
        var address = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(withSockaddr(&address) { bind(fd, $0, $1) } == 0)
        Darwin.close(fd)
        #expect(access(path, F_OK) == 0)

        let second = try IPCServer(path: path)
        second.close()
    }

    @Test func sendToHostIsFireAndForget() throws {
        let path = temporarySocketPath()
        #expect(sendToHost(.pinSent(ConnRef(conn: "c")), path: path) == false)
        let server = try IPCServer(path: path)
        defer { server.close() }
        #expect(sendToHost(.pinSent(ConnRef(conn: "c")), path: path))
        let accepted = try server.accept()
        #expect(try accepted.receive(timeout: 1) == .pinSent(ConnRef(conn: "c")))
    }
}

@Suite struct BuildInfoTests {
    @Test func comparesDottedVersions() {
        #expect(BuildInfo.isNewer("0.2.0", than: "0.1.0"))
        #expect(BuildInfo.isNewer("0.10.0", than: "0.9.3"))
        #expect(BuildInfo.isNewer("1.0", than: "0.9.9"))
        #expect(BuildInfo.isNewer("0.1.1", than: "0.1"))
        #expect(!BuildInfo.isNewer("0.1.0", than: "0.1.0"))
        #expect(!BuildInfo.isNewer("0.1", than: "0.1.0"))
        #expect(!BuildInfo.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func versionsThatAreNotDottedNumbersAreNeverNewer() {
        for (candidate, current) in [("HEAD-1a2b3c4", "0.1.0"), ("0.2.0", "HEAD-1a2b3c4"), ("0.2.0-beta", "0.1.0"), ("", "0.1.0"), ("1..0", "0.1.0")] {
            #expect(!BuildInfo.isNewer(candidate, than: current))
        }
    }
}

@Suite struct LogEventTests {
    @Test func cardSerialsShowTheLastFourDigits() {
        let start = LogEvent.operationStarted(conn: "12:p", kind: .sign, slot: 1, serial: "D2760001240100000006123456780000")
        #expect(start.message == "12:p op start: sign slot 1 card …5678")
        #expect(LogEvent.touchCacheRestarted(serial: "12345678", seconds: 15).message == "touch cache: card …5678 window restarted, 15 s")
        #expect(LogEvent.touchCacheRestarted(serial: "", seconds: 15).message == "touch cache: card ? window restarted, 15 s")
        #expect(LogEvent.operationStarted(conn: "12:s3", kind: .auth, slot: 3, serial: nil).message.hasSuffix("card ?"))
    }

    @Test func peerValuesAreCheckedBeforeTheyAreLogged() {
        #expect(LogEvent.touchQueued(conn: "4242:s17").message == "4242:s17 touch wait queued")
        for bad in ["x", "12:q", "12:s", ":p", "12:p\nforged line", "12:s1:p"] {
            #expect(LogEvent.touchQueued(conn: bad).message == "? touch wait queued")
        }
        #expect(LogEvent.hello(id: 3, role: .proxy, build: "0.1.0").message == "connection 3 hello: proxy, release 0.1.0")
        #expect(LogEvent.hello(id: 3, role: .proxy, build: "HEAD-1a2b3c4").message == "connection 3 hello: proxy, release HEAD-1a2b3c4")
        #expect(LogEvent.hello(id: 3, role: .proxy, build: "0.1.0\nforged line").message == "connection 3 hello: proxy, release ?")
        #expect(LogEvent.retireDecision(hostVersion: "0.1.0", helperBuild: "9 or anything").message.contains("helper release ? is newer"))
    }
}
