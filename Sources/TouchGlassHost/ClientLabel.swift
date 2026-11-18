import Foundation

/// Builds the short label that names what asked for a card operation, such as "git commit · touchglass"
/// or "ssh build-box", from a process and its parents. Pure apart from the `FileSource` it reads.
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
    public static func label(chain: [Link], files: FileSource) -> String? {
        guard let client = chain.first else { return nil }
        if let git = chain.first(where: { executableName($0) == "git" }) {
            return gitLabel(git, files: files)
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

    static func gitLabel(_ git: Link, files: FileSource) -> String {
        let invocation = GitArguments.parse(Array(git.argv.dropFirst()))
        guard let command = invocation.command else { return "git" }

        var words = "git \(command)"
        if command == "push", let remote = invocation.operands.first {
            words += " \(remote)"
        }

        let repository: Repository?
        if command == "clone" {
            repository = invocation.cloneTarget.map { Repository(name: $0, gitDirectory: nil) }
        } else {
            repository = git.cwd.flatMap { Repository.find(from: $0, files: files) }
        }
        if command == "rebase", let left = repository?.rebaseCommitsLeft(files: files), left > 0 {
            words += " (\(left) left)"
        }
        guard let name = repository?.name, !name.isEmpty else { return words }
        return words + separator + name
    }

    // MARK: Repository

    struct Repository: Equatable {
        var name: String
        /// The git directory: `.git`, or the directory a `.git` file points to.
        var gitDirectory: String?

        /// The top level is the nearest directory at or above `directory` that contains a `.git` entry.
        static func find(from directory: String, files: FileSource, maxDepth: Int = 64) -> Repository? {
            var current = (directory as NSString).standardizingPath
            for _ in 0..<maxDepth {
                let dotGit = (current as NSString).appendingPathComponent(".git")
                if files.exists(dotGit) {
                    return Repository(name: (current as NSString).lastPathComponent, gitDirectory: gitDirectory(dotGit, files: files))
                }
                let parent = (current as NSString).deletingLastPathComponent
                if parent == current || parent.isEmpty { return nil }
                current = parent
            }
            return nil
        }

        /// A worktree or submodule has a `.git` file with a `gitdir:` line instead of a directory.
        static func gitDirectory(_ dotGit: String, files: FileSource) -> String? {
            if files.isDirectory(dotGit) { return dotGit }
            guard let text = files.contents(dotGit),
                  let line = text.split(whereSeparator: \.isNewline).first,
                  line.hasPrefix("gitdir:") else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { return path }
            let base = (dotGit as NSString).deletingLastPathComponent
            return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
        }

        /// Commits still to apply after the current one, from the merge backend's `end` and `msgnum`.
        func rebaseCommitsLeft(files: FileSource) -> Int? {
            guard let gitDirectory else { return nil }
            let state = (gitDirectory as NSString).appendingPathComponent("rebase-merge")
            func number(_ file: String) -> Int? {
                files.contents((state as NSString).appendingPathComponent(file))
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            guard let end = number("end"), let current = number("msgnum") else { return nil }
            return max(0, end - current)
        }
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
