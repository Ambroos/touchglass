import Darwin
import Foundation
import Security

/// Decides whether the process on the other end of an accepted socket may talk to the host.
public protocol PeerVerifying: Sendable {
    func allows(socket: Int32) -> Bool
}

/// Admits only processes that run one of TouchGlass's helper executables from the host's own directory,
/// matched by code directory hash through the peer's audit token.
///
/// The same user ID is not enough: any process of the user could otherwise ask for a PIN in the panel,
/// with the context of a real card operation. The hashes are read again when a helper file changes, so
/// the helpers of an upgrade that replaced the files can still connect and make the old host retire.
public final class HelperSignatures: PeerVerifying, @unchecked Sendable {
    public static let helperNames = ["touchglass-pinentry", "touchglass-scdaemon"]

    private struct FileStamp: Equatable {
        var device: dev_t
        var inode: ino_t
        var modified: timespec

        static func == (a: FileStamp, b: FileStamp) -> Bool {
            a.device == b.device && a.inode == b.inode
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private let directory: String
    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, cdhash: String)] = [:]

    /// Trusts the helpers in `directory`: `Contents/MacOS` of the app bundle, or a build directory.
    public init(directory: String) {
        self.directory = directory
    }

    /// The helpers next to this process's executable, by the path it was launched with: after `brew
    /// upgrade` that path shows the new release, whose helpers must reach this host to make it retire.
    public static func besideThisExecutable() -> HelperSignatures {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return HelperSignatures(directory: executable.deletingLastPathComponent().path)
    }

    public func allows(socket: Int32) -> Bool {
        let hashes = currentHashes()
        guard !hashes.isEmpty,
              let code = Self.peerCode(socket: socket),
              let requirement = Self.requirement(cdhashes: hashes)
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The code directory hashes of the helpers on disk, in hex. A helper that is missing or unsigned
    /// is left out.
    func currentHashes() -> [String] {
        lock.withLock {
            Self.helperNames.compactMap { name in
                let path = directory + "/" + name
                guard let stamp = Self.stamp(path) else {
                    cache[name] = nil
                    return nil
                }
                if let cached = cache[name], cached.stamp == stamp { return cached.cdhash }
                guard let cdhash = Self.staticCDHash(path) else { return nil }
                cache[name] = (stamp, cdhash)
                return cdhash
            }
        }
    }

    private static func stamp(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStamp(device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec)
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

    /// The running code of the peer, from its audit token: unlike its PID, the token can't be reused.
    private static func peerCode(socket: Int32) -> SecCode? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
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
