// Drives an scdaemon-program the way gpg-agent does, for trying the proxy by hand.
//
//   fake-agent [--program <path>] [--pin <pin>] [--split] <command>...
//
// Starts the program (default: touchglass-scdaemon next to this executable) with --multi-server, runs the
// start-up handshake, then sends each command, answering NEEDPIN with the PIN padded with NUL bytes. Prints
// the replies with D line payloads replaced by their length. Set TOUCHGLASS_SCDAEMON_PROGRAM and
// FAKE_SCD_CONFIG to point the proxy at fake-scdaemon. The literal command "SOCKET" switches the
// remaining commands to a session on the socket that GETINFO socket_name returned.
//
// Example:
//   TOUCHGLASS_SCDAEMON_PROGRAM=.build/debug/fake-scdaemon fake-agent \
//     "KEYINFO AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "PKSIGN --hash=sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

import Darwin
import Foundation
import ScdTestSupport

var program = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("touchglass-scdaemon").path
var pin = "123456"
var split = false
var commands: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--program": program = args.popFirst() ?? program
    case "--pin": pin = args.popFirst() ?? pin
    case "--split": split = true
    default: commands.append(arg)
    }
}

let toChild = Pipe()
let fromChild = Pipe()
let process = Process()
process.executableURL = URL(fileURLWithPath: program)
process.arguments = ["--multi-server"]
process.standardInput = toChild
process.standardOutput = fromChild
do { try process.run() } catch {
    FileHandle.standardError.write(Data("fake-agent: cannot start \(program): \(error)\n".utf8))
    exit(1)
}

func show(_ line: [UInt8]) -> String {
    if line.starts(with: Array("D ".utf8)) { return "D <\(line.count - 2) bytes>" }
    if line.starts(with: Array("INQUIRE NEEDPIN".utf8)) { return "INQUIRE NEEDPIN …" }
    return String(decoding: line.map { $0 < 0x20 || $0 > 0x7E ? UInt8(ascii: ".") : $0 }, as: UTF8.self)
}

var driver = AgentDriver(input: fromChild.fileHandleForReading, output: toChild.fileHandleForWriting)
driver.splitWrites = split
print("< " + (driver.readHello() ?? "(no hello)"))
let socketReply = driver.transact("GETINFO socket_name")
let socketPath = String(decoding: socketReply.dataPayload, as: UTF8.self)
print("> GETINFO socket_name\n< D \(socketPath)\n< \(socketReply.final ?? "EOF")")
_ = driver.transact("OPTION event-signal=31")

let inquiries = AgentDriver.standardInquiries(pin: pin)
for command in commands {
    if command == "SOCKET" {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(socketPath.utf8)
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { print("! cannot connect to \(socketPath)"); exit(1) }
        driver = AgentDriver(socket: fd)
        print("(socket session) < " + (driver.readHello() ?? "(no hello)"))
        continue
    }
    let start = Date()
    print("> " + command)
    let reply = driver.transact(command, inquiries: inquiries)
    for line in reply.lines { print("< " + show(line)) }
    print("< \(reply.final ?? "EOF")  (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
}

toChild.fileHandleForWriting.closeFile()
process.waitUntilExit()
print("exit status \(process.terminationStatus)")
