import Foundation

/// Builds the short label that names what asked for a card operation, such as "git commit · touchglass"
/// or "ssh build-box", from a process and its parents. Pure: it uses only what the process table gives.
public enum ClientLabel {
    /// One process in the chain from the agent's client up through its parents.
    public struct Link: Sendable, Equatable {
        public var name: String
        public var argv: [String]
        public var cwd: String?

        public init(name: String, argv: [String], cwd: String? = nil) {
            self.name = name
            self.argv = argv
            self.cwd = cwd
        }
    }

    static let separator = " · "

    /// The label for a chain that starts at the agent's client. Returns `nil` for an empty chain.
    ///
    /// The nearest git process wins, so `git push` over ssh reads as git. Otherwise an ssh client names
    /// its destination, and anything else its executable name.
    public static func label(chain: [Link]) -> String? {
        guard let client = chain.first else { return nil }
        if let git = chain.first(where: { executableName($0) == "git" }) {
            return gitLabel(git)
        }
        if executableName(client) == "ssh" {
            if let host = SSHArguments.destination(Array(client.argv.dropFirst())) {
                return "ssh \(host)"
            }
            return "ssh"
        }
        let name = executableName(client)
        return name.isEmpty ? nil : name
    }

    static func executableName(_ link: Link) -> String {
        let argv0 = link.argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        // A login shell's argv[0] starts with "-".
        let fromArgv = argv0.hasPrefix("-") ? String(argv0.dropFirst()) : argv0
        return fromArgv.isEmpty ? link.name : fromArgv
    }

    // MARK: git

    static func gitLabel(_ git: Link) -> String {
        let invocation = GitArguments.parse(Array(git.argv.dropFirst()))
        guard let command = invocation.command else { return "git" }

        var words = "git \(command)"
        if ["push", "pull", "fetch"].contains(command), let remote = invocation.operands.first.flatMap(GitArguments.remoteLabel) {
            words += " \(remote)"
        }

        let name = command == "clone" ? invocation.cloneTarget : git.cwd.map(repositoryName)
        guard let name, !name.isEmpty else { return words }
        return words + separator + name
    }

    /// The repository's name, from the working directory of the git process alone. The lookup reads no
    /// files: opening or even checking a path in the client's repository can raise a macOS privacy prompt
    /// for a protected folder, or wait on an unreachable network volume.
    ///
    /// When git finds the repository by searching upwards, it changes to the top level of the working
    /// tree before it runs a command (`setup_git_directory_gently` in git's `setup.c`), so for `git
    /// commit`, `git tag` and `git rebase` the directory names the repository or worktree. With `GIT_DIR`
    /// set and no work tree, git stays where it started, and the label names that directory instead.
    static func repositoryName(_ directory: String) -> String {
        let name = (directory as NSString).lastPathComponent
        return name == "/" ? "" : name
    }
}

/// The parts of a git command line the label needs.
struct GitArguments: Equatable {
    var command: String?
    /// Arguments after the subcommand that are not options.
    var operands: [String] = []

    /// Global options that take the next argument as their value when written without `=`.
    static let globalOptionsWithValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"]
    /// Subcommand options that take a separate value, for the subcommands whose operands the label uses.
    static let subcommandOptionsWithValue: Set<String> = [
        "-o", "--push-option", "--repo", "--receive-pack", "--exec", "--upload-pack", "-u", "--recurse-submodules-default",
        "-b", "--branch", "--origin", "--template", "--reference", "--reference-if-able", "--separate-git-dir", "--depth",
        "--shallow-since", "--shallow-exclude", "--config", "--filter", "--server-option", "-j", "--jobs", "--bundle-uri",
    ]

    static func parse(_ arguments: [String]) -> GitArguments {
        var result = GitArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if result.command == nil {
                if argument == "--" { continue }
                if argument.hasPrefix("-") {
                    if globalOptionsWithValue.contains(argument) { index += 1 }
                    continue
                }
                result.command = argument
                continue
            }
            if argument == "--" {
                result.operands += arguments[index...]
                break
            }
            if argument.hasPrefix("-") {
                // `-u` on push means --set-upstream and takes no value; on clone it is --upload-pack.
                if subcommandOptionsWithValue.contains(argument), !(argument == "-u" && result.command != "clone") { index += 1 }
                continue
            }
            result.operands.append(argument)
        }
        return result
    }

    /// What the label shows for the repository operand of `git push`, `git pull` or `git fetch`: a remote
    /// name as written, or only the host of a URL. A URL can carry a user name, a token or a private path,
    /// and the panel shows on every Space and in screen shares. A local path shows nothing.
    static func remoteLabel(_ operand: String) -> String? {
        // A remote name has no slash, colon or at sign.
        guard operand.contains(where: { "/:@".contains($0) }) else { return operand }
        var rest = Substring(operand)
        if let scheme = rest.range(of: "://") {
            guard rest[..<scheme.lowerBound] != "file" else { return nil }
            rest = rest[scheme.upperBound...]
            if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        } else {
            // git reads "[user@]host:path" as scp-like syntax only when no slash comes before the colon.
            let colon = rest.hasPrefix("[") || rest.contains("@[")
                ? rest.firstIndex(of: "]").flatMap { rest[$0...].firstIndex(of: ":") }
                : rest.firstIndex(of: ":")
            guard let colon, !rest[..<colon].contains("/") else { return nil }
            rest = rest[..<colon]
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            return Self.bareHost(rest, hasPort: false)
        }
        return Self.bareHost(rest, hasPort: true)
    }

    /// A host without IPv6 brackets or, when `hasPort`, a port.
    private static func bareHost(_ authority: Substring, hasPort: Bool) -> String? {
        var host = authority
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = host[host.index(after: host.startIndex)..<close]
        } else if hasPort, let colon = host.lastIndex(of: ":") {
            host = host[..<colon]
        }
        return host.isEmpty ? nil : String(host)
    }

    /// The directory `git clone` creates: the second operand, or the last path component of the URL
    /// without `.git`.
    var cloneTarget: String? {
        if operands.count >= 2 {
            return (operands[1] as NSString).lastPathComponent
        }
        guard var url = operands.first else { return nil }
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        // scp-like "host:path" and URLs both end in the repository name.
        let name = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}

/// The destination of an `ssh` command line, parsed with OpenSSH's option rules.
enum SSHArguments {
    /// Single-letter options that take a value, from OpenSSH's getopt string.
    static let optionsWithValue: Set<Character> = ["B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "P", "p", "Q", "R", "S", "W", "w"]

    /// The host of the first operand, without a user name, port or `ssh://` scheme.
    static func destination(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                return index < arguments.count ? host(arguments[index]) : nil
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                // Flags combine ("-vp 22"); the first flag that takes a value ends the group, and its
                // value is the rest of the group or the next argument.
                for (offset, flag) in argument.dropFirst().enumerated() where optionsWithValue.contains(flag) {
                    if offset == argument.count - 2 { index += 1 }
                    break
                }
                continue
            }
            return host(argument)
        }
        return nil
    }

    static func host(_ destination: String) -> String? {
        var rest = Substring(destination)
        if rest.hasPrefix("ssh://") {
            rest = rest.dropFirst("ssh://".count)
            if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                rest = rest[rest.index(after: rest.startIndex)..<close]
            } else if let colon = rest.lastIndex(of: ":") {
                rest = rest[..<colon]
            }
        } else if let at = rest.lastIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
        }
        return rest.isEmpty ? nil : String(rest)
    }
}
