import Darwin
import Foundation

extension PinentryServer {
    /// Hands the rest of the session to pinentry-mac after the greeting has already gone out.
    ///
    /// Starts pinentry-mac as a child, replays the recorded setup commands while discarding its greeting and replies, sends the pending request, and then relays bytes both ways until the child exits. This process then exits with the child's status. If pinentry-mac can't be started or rejects the replay, answers the request with "No pinentry" and returns to the command loop.
    func handoff(_ request: [UInt8]) {
        guard let child = startFallback() else {
            reply(Assuan.noPinentry)
            return
        }
        guard replay(to: child), writeAll(child.stdin, request + [0x0A]) else {
            log("replay to fallback failed")
            kill(child.pid, SIGKILL)
            _ = waitExitCode(child.pid)
            close(child.stdin)
            close(child.stdout.fd)
            reply(Assuan.noPinentry)
            return
        }
        relay(child)
    }

    struct Child {
        let pid: pid_t
        let stdin: Int32
        let stdout: LineInput
    }

    func startFallback() -> Child? {
        guard FileManager.default.isExecutableFile(atPath: config.fallbackPinentry) else {
            log("fallback pinentry missing: \(config.fallbackPinentry)")
            return nil
        }
        var toChild: [Int32] = [0, 0]
        var fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { return nil }
        for fd in [toChild[1], fromChild[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        let pid = spawn(config.fallbackPinentry, arguments, stdin: toChild[0], stdout: fromChild[1], stderr: 2)
        close(toChild[0])
        close(fromChild[1])
        guard let pid else {
            close(toChild[1])
            close(fromChild[0])
            log("spawn of fallback failed")
            return nil
        }
        log("started fallback pid \(pid)")
        return Child(pid: pid, stdin: toChild[1], stdout: LineInput(fd: fromChild[0]))
    }

    /// Reads the greeting, then sends each recorded command and discards its reply.
    func replay(to child: Child) -> Bool {
        guard let greeting = readResponse(from: child), greeting.starts(with: Array("OK".utf8)) else { return false }
        for line in transcript {
            guard writeAll(child.stdin, line + [0x0A]) else { return false }
            while true {
                guard let response = readResponse(from: child) else { return false }
                if response.starts(with: Array("OK".utf8)) || response.starts(with: Array("ERR".utf8)) { break }
                if response.starts(with: Array("INQUIRE".utf8)) {
                    guard writeAll(child.stdin, Array("CAN\n".utf8)) else { return false }
                }
            }
        }
        log("replayed \(transcript.count) commands")
        return true
    }

    /// Reads one line from the child, giving up after 5 seconds. A terminating signal stops the child and exits.
    func readResponse(from child: Child) -> [UInt8]? {
        let deadline = now() + 5
        while true {
            if let line = child.stdout.nextLine() { return line }
            if child.stdout.reachedEOF || now() >= deadline { return nil }
            let ready = waitReadable([child.stdout.fd, signalPipe], timeout: deadline - now())
            if ready.contains(signalPipe), let sig = drainSignals(signalPipe).first {
                kill(child.pid, sig)
                exit(waitExitCode(child.pid))
            }
            if ready.contains(child.stdout.fd) {
                child.stdout.fill()
            }
        }
    }

    /// Copies agent input to the child and child output to the agent until the child closes its output, forwarding signals. Never returns.
    func relay(_ child: Child) -> Never {
        log("relaying to fallback")
        var childInput: Int32? = child.stdin
        let pending = input.takeBuffer()
        if !pending.isEmpty, !writeAll(child.stdin, pending) {
            close(child.stdin)
            childInput = nil
        }
        if input.reachedEOF, let fd = childInput {
            close(fd)
            childInput = nil
        }
        // Bytes the child sent after its last replayed reply belong to the agent.
        let early = child.stdout.takeBuffer()
        if !early.isEmpty { writeAll(output, early) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var agentOpen = !input.reachedEOF
        while true {
            var fds = [child.stdout.fd, signalPipe]
            if agentOpen { fds.append(input.fd) }
            let ready = waitReadable(fds, timeout: nil)
            if ready.contains(signalPipe) {
                for sig in drainSignals(signalPipe) {
                    kill(child.pid, sig)
                }
            }
            if agentOpen, ready.contains(input.fd) {
                let n = read(input.fd, &buffer, buffer.count)
                if n > 0, let fd = childInput {
                    if !writeAll(fd, Array(buffer[0..<n])) {
                        close(fd)
                        childInput = nil
                    }
                } else if n == 0 || (n < 0 && errno != EINTR) {
                    agentOpen = false
                    if let fd = childInput {
                        close(fd)
                        childInput = nil
                    }
                }
            }
            if ready.contains(child.stdout.fd) {
                let n = read(child.stdout.fd, &buffer, buffer.count)
                if n > 0 {
                    writeAll(output, Array(buffer[0..<n]))
                } else if n == 0 || errno != EINTR {
                    break
                }
            }
        }
        let code = waitExitCode(child.pid)
        log("fallback exited with \(code)")
        exit(code)
    }
}
