import Foundation
import Testing
@testable import TouchGlassHost

/// A process table built from plain values. Every name, path and PID here is made up.
final class FakeProcesses: ProcessSource, @unchecked Sendable {
    struct Entry {
        var record: ProcessRecord
        var argv: [String]?
        var cwd: String?
        var sockets: [UnixSocketRecord] = []
    }

    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]

    func add(_ pid: Int32, ppid: Int32, name: String, argv: [String]?, cwd: String? = nil, uid: UInt32 = 501, start: Double = 1_000, sockets: [UnixSocketRecord] = []) {
        lock.withLock {
            entries[pid] = Entry(record: ProcessRecord(pid: pid, ppid: ppid, uid: uid, startTime: start, name: name), argv: argv, cwd: cwd, sockets: sockets)
        }
    }

    func remove(_ pid: Int32) {
        _ = lock.withLock { entries.removeValue(forKey: pid) }
    }

    func processes(uid: UInt32) -> [Int32] {
        lock.withLock { entries.values.filter { $0.record.uid == uid }.map(\.record.pid).sorted() }
    }

    func record(_ pid: Int32) -> ProcessRecord? { lock.withLock { entries[pid]?.record } }

    func arguments(_ pid: Int32) -> ProcessArguments? {
        lock.withLock { entries[pid]?.argv.map { ProcessArguments(executable: "/usr/bin/" + ($0.first ?? ""), argv: $0) } }
    }

    func currentDirectory(_ pid: Int32) -> String? { lock.withLock { entries[pid]?.cwd } }

    func unixSockets(_ pid: Int32) -> [UnixSocketRecord] { lock.withLock { entries[pid]?.sockets ?? [] } }
}

/// A file tree: directories and files with contents.
struct FakeFiles: FileSource {
    var directories: Set<String> = []
    var files: [String: String] = [:]

    func exists(_ path: String) -> Bool { directories.contains(path) || files[path] != nil }
    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func contents(_ path: String) -> String? { files[path] }
}

@Suite struct ClientResolverTests {
    static let uid: UInt32 = 501
    static let agentPID: Int32 = 100
    static let socketDir = "/run/example/gnupg"

    /// An agent with one accepted connection per client: `(agent-side pcb, client-side pcb, ssh?)`.
    func agent(_ table: FakeProcesses, connections: [(UInt64, UInt64, Bool)], pid: Int32 = agentPID) {
        let sockets = [UnixSocketRecord(pcb: 1, peerPCB: 0, path: Self.socketDir + "/S.gpg-agent")]
            + connections.map { UnixSocketRecord(pcb: $0.0, peerPCB: $0.1, path: Self.socketDir + ($0.2 ? "/S.gpg-agent.ssh" : "/S.gpg-agent")) }
            // The agent's own connection to scdaemon is not a client.
            + [UnixSocketRecord(pcb: 90, peerPCB: 91, path: "", peerPath: Self.socketDir + "/S.scdaemon")]
        table.add(pid, ppid: 1, name: "gpg-agent", argv: ["gpg-agent", "--daemon"], start: 10, sockets: sockets)
    }

    func client(pcb: UInt64, agentPCB: UInt64, ssh: Bool = false) -> [UnixSocketRecord] {
        [UnixSocketRecord(pcb: pcb, peerPCB: agentPCB, peerPath: Self.socketDir + (ssh ? "/S.gpg-agent.ssh" : "/S.gpg-agent"))]
    }

    func resolver(_ table: FakeProcesses, files: FakeFiles = FakeFiles(), budget: Duration = .seconds(5)) -> ClientResolver {
        ClientResolver(processes: table, files: files, uid: Self.uid, budget: budget)
    }

    let repo = FakeFiles(directories: ["/src/touchglass/.git"])

    /// A shell, a `git commit` in it, and the gpg it runs, connected to the agent.
    func commitTree(_ table: FakeProcesses, gpgPID: Int32 = 300, gitPID: Int32 = 200, start: Double = 2_000, gitArgv: [String] = ["git", "commit", "-m", "Example"], cwd: String = "/src/touchglass") {
        table.add(50, ppid: 1, name: "zsh", argv: ["-zsh"], cwd: "/home/example")
        table.add(gitPID, ppid: 50, name: "git", argv: gitArgv, cwd: cwd, start: start)
        table.add(gpgPID, ppid: gitPID, name: "gpg", argv: ["gpg", "--status-fd=2", "-bsau", "ABCDEF"], cwd: cwd, start: start + 0.1, sockets: client(pcb: UInt64(gpgPID), agentPCB: UInt64(gpgPID) + 1))
    }

    // MARK: Choosing the client

    @Test func oneClientIsLabelled() {
        let table = FakeProcesses()
        agent(table, connections: [(301, 300, false)])
        commitTree(table)
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: false)) == "git commit · touchglass")
        // The same client is not an SSH login.
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: true)) == nil)
    }

    @Test func noAgentOrNoClientsGivesNoLabel() {
        let table = FakeProcesses()
        commitTree(table)
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: false)) == nil)
        agent(table, connections: [])
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: false)) == nil)
    }

    @Test func aLongLivedClientGivesWayToTheNewestOne() {
        let table = FakeProcesses()
        agent(table, connections: [(301, 300, false), (401, 400, false)])
        commitTree(table, start: 5_000)
        table.add(400, ppid: 50, name: "gpg-connect-agent", argv: ["gpg-connect-agent"], start: 1_000, sockets: client(pcb: 400, agentPCB: 401))
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: false)) == "git commit · touchglass")
    }

    @Test func clientsThatStartedTogetherAreAmbiguous() {
        let table = FakeProcesses()
        agent(table, connections: [(301, 300, false), (401, 400, false)])
        commitTree(table, start: 5_000)
        table.add(400, ppid: 50, name: "gpg", argv: ["gpg", "--decrypt", "notes.gpg"], start: 5_002, sockets: client(pcb: 400, agentPCB: 401))
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: false)) == nil)
    }

    @Test func clientsThatStartedTogetherAndReadTheSameShareTheLabel() {
        let table = FakeProcesses()
        agent(table, connections: [(301, 300, false), (601, 600, false)])
        commitTree(table, start: 5_000)
        commitTree(table, gpgPID: 600, gitPID: 500, start: 5_001)
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: false)) == "git commit · touchglass")
    }

    @Test func sshClientOnTheSSHSocket() {
        let table = FakeProcesses()
        agent(table, connections: [(301, 300, false), (701, 700, true)])
        commitTree(table)
        table.add(700, ppid: 50, name: "ssh", argv: ["ssh", "-p", "22", "-i", "key", "-o", "X=Y", "host", "cmd"], sockets: client(pcb: 700, agentPCB: 701, ssh: true))
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: true)) == "ssh host")
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: false)) == "git commit · touchglass")
    }

    @Test func sshUnderGitPushReadsAsGit() {
        let table = FakeProcesses()
        agent(table, connections: [(701, 700, true)])
        table.add(200, ppid: 50, name: "git", argv: ["git", "push", "-u", "origin", "main"], cwd: "/src/touchglass/Sources")
        table.add(700, ppid: 200, name: "ssh", argv: ["ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@example.com", "git-receive-pack 'example/touchglass.git'"], sockets: client(pcb: 700, agentPCB: 701, ssh: true))
        #expect(resolver(table, files: repo).label(for: .agentClient(ssh: true)) == "git push origin · touchglass")
    }

    @Test func expiredBudgetGivesNoLabel() {
        let table = FakeProcesses()
        agent(table, connections: [(301, 300, false)])
        commitTree(table)
        #expect(resolver(table, files: repo, budget: .zero).label(for: .agentClient(ssh: false)) == nil)
    }

    @Test func agentPIDIsCachedUntilItGoesAway() {
        let table = FakeProcesses()
        agent(table, connections: [(301, 300, false)])
        commitTree(table)
        let resolver = resolver(table, files: repo)
        #expect(resolver.agentPIDs() == [Self.agentPID])
        table.remove(Self.agentPID)
        agent(table, connections: [(301, 300, false)], pid: 150)
        #expect(resolver.agentPIDs() == [150])
        #expect(resolver.label(for: .agentClient(ssh: false)) == "git commit · touchglass")
    }

    // MARK: Owner PID

    @Test func ownerPIDIsLabelledWithoutAScan() {
        let table = FakeProcesses()
        commitTree(table)
        #expect(resolver(table, files: repo).label(for: .owner(300)) == "git commit · touchglass")
    }

    @Test func missingOrForeignProcessGivesNoLabel() {
        let table = FakeProcesses()
        commitTree(table)
        table.add(800, ppid: 1, name: "gpg", argv: ["gpg"], uid: 0)
        #expect(resolver(table).label(for: .owner(999)) == nil)
        #expect(resolver(table).label(for: .owner(800)) == nil)
    }

    @Test func unreadableArgumentsFallBackToTheProcessName() {
        let table = FakeProcesses()
        table.add(300, ppid: 250, name: "gpg", argv: nil)
        // The parent exited: the walk stops at the client.
        #expect(resolver(table).label(for: .owner(300)) == "gpg")
    }

    @Test func ownerValueParsing() {
        #expect(ClientQuery.ownerPID("4242/501 example-host") == 4242)
        #expect(ClientQuery.ownerPID("4242 example-host") == 4242)
        #expect(ClientQuery.ownerPID("0/501 example-host") == nil)
        #expect(ClientQuery.ownerPID("host") == nil)
        #expect(ClientQuery.ownerPID(nil) == nil)
    }

    // MARK: Labels

    func label(_ chain: [ClientLabel.Link], files: FakeFiles = FakeFiles()) -> String? {
        ClientLabel.label(chain: chain, files: files)
    }

    @Test func gpgRunByHand() {
        #expect(label([.init(name: "gpg", argv: ["gpg", "--sign", "notes.txt"]), .init(name: "zsh", argv: ["-zsh"])]) == "gpg")
        #expect(label([.init(name: "gpg", argv: ["/opt/example/bin/gpg2", "-d"])]) == "gpg2")
        #expect(label([]) == nil)
    }

    @Test func gitSubcommandAfterGlobalOptions() {
        let chain: [ClientLabel.Link] = [
            .init(name: "gpg", argv: ["gpg", "-bsau", "KEY"]),
            .init(name: "git", argv: ["git", "-C", "path", "-c", "k=v", "--no-pager", "--git-dir=x", "--work-tree", "y", "commit", "--amend"], cwd: "/src/touchglass"),
        ]
        #expect(label(chain, files: repo) == "git commit · touchglass")
    }

    @Test func gitSubcommands() {
        func git(_ arguments: String...) -> String? {
            label([.init(name: "git", argv: ["git"] + arguments, cwd: "/src/touchglass")], files: repo)
        }
        #expect(git("tag", "-s", "v1.0", "-m", "Release") == "git tag · touchglass")
        #expect(git("merge", "--no-ff", "feature") == "git merge · touchglass")
        #expect(git("cherry-pick", "abc123") == "git cherry-pick · touchglass")
        #expect(git("am", "-3") == "git am · touchglass")
        #expect(git("push", "origin", "main") == "git push origin · touchglass")
        #expect(git("push", "-o", "ci.skip", "--force-with-lease", "upstream") == "git push upstream · touchglass")
        #expect(git("push") == "git push · touchglass")
        #expect(git("pull", "--rebase") == "git pull · touchglass")
        #expect(git("fetch", "--all") == "git fetch · touchglass")
        #expect(git() == "git")
    }

    @Test func gitCloneNamesTheNewDirectory() {
        func clone(_ arguments: String...) -> String? {
            label([.init(name: "ssh", argv: ["ssh", "git@example.com"]), .init(name: "git", argv: ["git", "clone"] + arguments, cwd: "/src")])
        }
        #expect(clone("git@example.com:example/widget.git") == "git clone · widget")
        #expect(clone("--depth", "1", "ssh://git@example.com/example/widget.git/") == "git clone · widget")
        #expect(clone("-b", "main", "git@example.com:example/widget.git", "gadget") == "git clone · gadget")
    }

    @Test func toplevelLookupThroughNestedDirectories() {
        let files = FakeFiles(directories: ["/src/outer/.git", "/src/outer/vendor/inner/.git"])
        func repoName(_ cwd: String) -> String? {
            ClientLabel.Repository.find(from: cwd, files: files)?.name
        }
        #expect(repoName("/src/outer/Sources/Deep/Deeper") == "outer")
        #expect(repoName("/src/outer/vendor/inner/lib") == "inner")
        #expect(repoName("/src/outer") == "outer")
        #expect(repoName("/elsewhere/project") == nil)
        // A git command outside any repository still gets a label, without a name.
        #expect(label([.init(name: "git", argv: ["git", "tag", "-v", "v1"], cwd: "/elsewhere")], files: files) == "git tag")
    }

    @Test func rebaseCountsCommitsLeftInAWorktree() {
        // A worktree's `.git` is a file that points into the main repository's git directory.
        let files = FakeFiles(
            directories: ["/src/main/.git"],
            files: [
                "/src/wt-feature/.git": "gitdir: ../main/.git/worktrees/wt-feature\n",
                "/src/main/.git/worktrees/wt-feature/rebase-merge/end": "5\n",
                "/src/main/.git/worktrees/wt-feature/rebase-merge/msgnum": "3\n",
            ]
        )
        let rebase = ClientLabel.Link(name: "git", argv: ["git", "rebase", "-i", "main"], cwd: "/src/wt-feature/Sources")
        #expect(label([rebase], files: files) == "git rebase (2 left) · wt-feature")

        // The last commit, or no readable state: no count.
        var last = files
        last.files["/src/main/.git/worktrees/wt-feature/rebase-merge/msgnum"] = "5"
        #expect(label([rebase], files: last) == "git rebase · wt-feature")
        let plain = FakeFiles(directories: ["/src/wt-feature/.git"])
        #expect(label([rebase], files: plain) == "git rebase · wt-feature")
    }

    // MARK: ssh options

    @Test func sshDestinationParsing() {
        func host(_ arguments: String...) -> String? { SSHArguments.destination(arguments) }
        #expect(host("-p", "22", "-i", "key", "-o", "X=Y", "host", "cmd") == "host")
        #expect(host("user@host") == "host")
        #expect(host("-l", "user", "host") == "host")
        #expect(host("-vp", "2222", "host") == "host")
        #expect(host("-p2222", "-A", "host") == "host")
        #expect(host("-J", "jump@bastion", "-L", "8080:localhost:80", "target") == "target")
        #expect(host("ssh://user@host.example:2222") == "host.example")
        #expect(host("ssh://[2001:db8::1]:22/") == "2001:db8::1")
        #expect(host("-T", "--", "host") == "host")
        #expect(host("-V") == nil)
        #expect(label([.init(name: "ssh", argv: ["ssh", "-N"])]) == "ssh")
    }
}
