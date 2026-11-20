import Darwin
import Foundation

/// One process as the client resolver sees it.
public struct ProcessRecord: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    /// Start time, in seconds since 1970.
    public var startTime: Double
    /// The kernel's short command name, at most 16 bytes.
    public var name: String

    public init(pid: Int32, ppid: Int32, uid: UInt32, startTime: Double, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.startTime = startTime
        self.name = name
    }
}

/// A process's executable path and arguments.
public struct ProcessArguments: Sendable, Equatable {
    public var executable: String
    /// The arguments, `argv[0]` included.
    public var argv: [String]

    public init(executable: String, argv: [String]) {
        self.executable = executable
        self.argv = argv
    }
}

/// One Unix-domain socket a process holds open.
public struct UnixSocketRecord: Sendable, Equatable {
    /// Opaque kernel handle of this socket's protocol control block.
    public var pcb: UInt64
    /// The handle of the connected peer's protocol control block, or 0 when not connected.
    public var peerPCB: UInt64
    /// The bound address. An accepted socket carries its listener's path.
    public var path: String
    /// The address of the socket this one connected to.
    public var peerPath: String

    public init(pcb: UInt64, peerPCB: UInt64, path: String = "", peerPath: String = "") {
        self.pcb = pcb
        self.peerPCB = peerPCB
        self.path = path
        self.peerPath = peerPath
    }
}

/// Read access to the process table. `LibprocProcessSource` reads the live system; tests use tables.
public protocol ProcessSource: Sendable {
    /// The PIDs of every process of the user `uid`.
    func processes(uid: UInt32) -> [Int32]
    func record(_ pid: Int32) -> ProcessRecord?
    func arguments(_ pid: Int32) -> ProcessArguments?
    /// The path of the file the kernel runs for `pid`, symlinks resolved. Unlike `argv[0]`, the process can't set it.
    func executablePath(_ pid: Int32) -> String?
    func currentDirectory(_ pid: Int32) -> String?
    func unixSockets(_ pid: Int32) -> [UnixSocketRecord]
}

/// The live process table, through libproc and `sysctl`. Processes of other users are unreadable and
/// come back as `nil` or empty.
public struct LibprocProcessSource: ProcessSource {
    public init() {}

    public func processes(uid: UInt32) -> [Int32] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        // Leave room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    public func record(_ pid: Int32) -> ProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcessRecord(
            pid: pid,
            ppid: Int32(bitPattern: info.pbi_ppid),
            uid: info.pbi_uid,
            startTime: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
            name: name
        )
    }

    /// Reads `KERN_PROCARGS2`: argc as an `Int32`, the executable path, padding NULs, then argv and the
    /// environment. Only argv is returned; the environment is never read past argc strings.
    public func arguments(_ pid: Int32) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return Self.parseProcArgs(buffer.prefix(size))
    }

    static func parseProcArgs(_ bytes: ArraySlice<UInt8>) -> ProcessArguments? {
        guard bytes.count > 4 else { return nil }
        let start = bytes.startIndex
        let argc = Int(bytes[start]) | Int(bytes[start + 1]) << 8 | Int(bytes[start + 2]) << 16 | Int(bytes[start + 3]) << 24
        var index = start + 4

        func nextString() -> String? {
            guard index < bytes.endIndex else { return nil }
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.endIndex
            let string = String(decoding: bytes[index..<end], as: UTF8.self)
            index = end
            return string
        }

        guard let executable = nextString() else { return nil }
        // Skip the NUL padding after the executable path.
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }

        var argv: [String] = []
        while argv.count < argc, let argument = nextString() {
            argv.append(argument)
            index += 1
        }
        return ProcessArguments(executable: executable, argv: argv)
    }

    public func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift doesn't import.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The kernel's path for the process's working directory. A query of the process table: it opens and
    /// checks nothing on disk.
    public func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    public func unixSockets(_ pid: Int32) -> [UnixSocketRecord] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let bytes = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }

        var sockets: [UnixSocketRecord] = []
        for fd in fds.prefix(Int(bytes) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_UN else { continue }
            var unix = info.psi.soi_proto.pri_un
            sockets.append(UnixSocketRecord(
                pcb: info.psi.soi_pcb,
                peerPCB: unix.unsi_conn_pcb,
                path: Self.path(&unix.unsi_addr),
                peerPath: Self.path(&unix.unsi_caddr)
            ))
        }
        return sockets
    }

    /// The path in a `sockaddr_un` union member, which starts with the length and family bytes.
    private static func path<T>(_ address: inout T) -> String {
        withUnsafeBytes(of: &address) { raw in
            String(decoding: raw.dropFirst(2).prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
