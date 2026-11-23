import Darwin
import Foundation
import Security

/// What the host learned about the process on the other end of an accepted socket, from the kernel.
public struct PeerIdentity: Sendable, Equatable {
    /// The peer's process ID, from the same audit token that was checked. Nil if the kernel didn't say.
    public var pid: Int32?
    /// Whether the peer runs one of TouchGlass's own helpers. Only a verified peer may ask for a PIN.
    public var verified: Bool

    public init(pid: Int32?, verified: Bool) {
        self.pid = pid
        self.verified = verified
    }
}

/// Identifies the process on the other end of an accepted socket.
public protocol PeerVerifying: Sendable {
    func identify(socket: Int32) -> PeerIdentity
}

/// Verifies processes that run one of TouchGlass's helper executables from a trusted directory,
/// matched by code directory hash through the peer's audit token.
///
/// The same user ID is not enough to ask for a PIN: any process of the user could otherwise show a
/// PIN prompt in the panel, with the context of a real card operation, and receive what is typed. The
/// hashes are read again when a helper file changes, so the helpers of an upgrade that replaced the
/// files are verified too and can make the old host retire.
public final class HelperSignatures: PeerVerifying, @unchecked Sendable {
    public static let helperNames = ["touchglass-pinentry", "touchglass-scdaemon"]

    /// What identifies a helper file's contents without reading it. A copy that keeps the inode and
    /// restores the modification time, such as `cp -p` over the file, still changes the size or the
    /// status change time, which a user can't set.
    private struct FileStamp: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: timespec
        var changed: timespec

        static func == (a: FileStamp, b: FileStamp) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }

    /// The directories whose helpers are trusted, in order.
    public let directories: [String]
    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, cdhash: String)] = [:]

    /// Trusts the helpers in each of `directories`: `Contents/MacOS` of an app bundle, or a build directory.
    public init(directories: [String]) {
        var seen = Set<String>()
        self.directories = directories.filter { seen.insert($0).inserted }
    }

    public convenience init(directory: String) {
        self.init(directories: [directory])
    }

    /// The verifier for the host running at `executablePath`; see `trustedDirectories(hostExecutable:)`.
    public static func forHost(executablePath: String? = Bundle.main.executablePath) -> HelperSignatures {
        HelperSignatures(directories: trustedDirectories(hostExecutable: executablePath ?? CommandLine.arguments[0]))
    }

    /// The directories whose helpers may talk to the host at `hostExecutable`: the directory that the
    /// host runs from, with symlinks resolved, and for a Homebrew keg, the same directory through the
    /// formula's `opt` link.
    ///
    /// The path that the host was launched through doesn't count: whoever starts the host chooses it.
    /// `open` resolves symlinks anyway, so a host that a helper started through the `opt` link runs from
    /// the versioned `Cellar` keg. `brew upgrade` deletes that keg and points the link at the next one,
    /// and the launchers that `touchglass install` writes run the helpers through the link, as its
    /// `stable_app` names it. Without the link, the old host would trust no helper, and the next
    /// release's helpers couldn't say hello to make it retire. The link only says where to look: a peer
    /// must still match the code directory hash of a helper file found there.
    public static func trustedDirectories(hostExecutable: String) -> [String] {
        let directory = URL(fileURLWithPath: hostExecutable).standardizedFileURL.deletingLastPathComponent().path
        let resolved = realpath(directory, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? directory
        return [resolved] + [homebrewOptPath(resolved)].compactMap { $0 }
    }

    /// `<prefix>/opt/<formula>/<rest>` for `<prefix>/Cellar/<formula>/<version>/<rest>`, or nil, like
    /// `stable_app` in `scripts/touchglass`.
    static func homebrewOptPath(_ path: String) -> String? {
        guard let cellar = path.range(of: "/Cellar/", options: .backwards) else { return nil }
        let prefix = path[..<cellar.lowerBound]
        let parts = path[cellar.upperBound...].split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return "\(prefix)/opt/\(parts[0])/\(parts[2])"
    }

    public func identify(socket: Int32) -> PeerIdentity {
        guard let token = Self.peerToken(socket: socket) else { return PeerIdentity(pid: nil, verified: false) }
        // `audit_token_to_pid` in libbsm reads the same field.
        let pid = Int32(bitPattern: token.val.5)
        let hashes = currentHashes()
        guard !hashes.isEmpty,
              let code = Self.code(token: token),
              let requirement = Self.requirement(cdhashes: hashes)
        else { return PeerIdentity(pid: pid, verified: false) }
        return PeerIdentity(pid: pid, verified: SecCodeCheckValidity(code, [], requirement) == errSecSuccess)
    }

    /// Whether the peer on `socket` runs one of the trusted helpers.
    public func allows(socket: Int32) -> Bool {
        identify(socket: socket).verified
    }

    /// The code directory hashes of the helpers on disk, in hex, without repeats. A helper that is
    /// missing or unsigned is left out.
    func currentHashes() -> [String] {
        lock.withLock {
            var seen = Set<String>()
            return directories.flatMap { directory in
                Self.helperNames.compactMap { name -> String? in
                    let path = directory + "/" + name
                    guard let stamp = Self.stamp(path) else {
                        cache[path] = nil
                        return nil
                    }
                    if let cached = cache[path], cached.stamp == stamp { return cached.cdhash }
                    guard let cdhash = Self.staticCDHash(path) else { return nil }
                    cache[path] = (stamp, cdhash)
                    return cdhash
                }
            }.filter { seen.insert($0).inserted }
        }
    }

    private static func stamp(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec)
    }

    private static func staticCDHash(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The peer's audit token: unlike its PID, the token can't be reused by another process.
    private static func peerToken(socket: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        return token
    }

    /// The running code of the process that `token` names.
    private static func code(token: audit_token_t) -> SecCode? {
        var token = token
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func requirement(cdhashes: [String]) -> SecRequirement? {
        let text = cdhashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
