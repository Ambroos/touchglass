import Foundation

/// What the host knows about the process behind a card operation when it asks for a label.
public enum ClientQuery: Sendable, Equatable {
    /// The client PID from the agent's `OPTION owner`, which a pinentry request carries.
    case owner(Int32)
    /// A prompt from the pinentry with PID `pinentry`, with the client PID from its `OPTION owner`, if
    /// any. The label names the owner only when gpg-agent started the pinentry and the owner is one of
    /// that agent's clients; a pinentry that something else started is named by its parent.
    case pinentry(Int32, owner: Int32?)
    /// One of the agent's connected clients: an ssh client for an SSH login, any other client for a
    /// signature or decryption. `agent` is the gpg-agent the proxy reported; a proxy that doesn't report
    /// one leaves it `nil`, and the lookup then searches every gpg-agent of the user.
    case agentClient(ssh: Bool, agent: Int32? = nil)

    /// The PID in an `owner` value, "<pid>/<uid> <host>" or "<pid> <host>". `nil` for PID 0 or garbage.
    public static func ownerPID(_ owner: String?) -> Int32? {
        guard let owner else { return nil }
        let digits = owner.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }
}

/// Names the process that asked for a card operation. Implementations must be safe to call off the
/// main thread.
public protocol ClientResolving: Sendable {
    /// A short label such as "git commit · touchglass", or `nil` when the answer is unknown or ambiguous.
    func label(for query: ClientQuery) -> String?
}

/// Finds gpg-agent's clients by matching the agent's connected Unix sockets with the sockets of the
/// user's other processes, then labels a client from its parent chain.
///
/// Best effort and bounded: each lookup gives up after `budget`. It keeps only the agent's PID between
/// lookups.
public final class ClientResolver: ClientResolving, @unchecked Sendable {
    /// Clients that started more than this long before the newest one are taken as long-lived bystanders,
    /// such as an idle `gpg-connect-agent`.
    public static let recentWindow: TimeInterval = 10
    /// How many processes the parent walk visits, the client included.
    public static let maxChainLength = 6

    private let processes: ProcessSource
    private let uid: UInt32
    private let budget: Duration
    private let lock = NSLock()
    private var cachedAgents: [Int32] = []

    public init(processes: ProcessSource = LibprocProcessSource(), uid: UInt32 = getuid(), budget: Duration = .milliseconds(50)) {
        self.processes = processes
        self.uid = uid
        self.budget = budget
    }

    public func label(for query: ClientQuery) -> String? {
        let deadline = ContinuousClock.now + budget
        switch query {
        case .owner(let pid):
            guard processes.record(pid)?.uid == uid else { return nil }
            return chain(startingAt: pid, deadline: deadline).flatMap(ClientLabel.promptLabel)
        case .pinentry(let pid, let owner):
            return labelForPinentry(pid, owner: owner, deadline: deadline)
        case .agentClient(let ssh, let agent):
            return labelForAgentClient(ssh: ssh, agent: agent, deadline: deadline)
        }
    }

    // MARK: Choosing the client

    struct AgentClient: Equatable {
        var pid: Int32
        var startTime: Double
        var ssh: Bool
    }

    private func labelForAgentClient(ssh: Bool, agent: Int32?, deadline: ContinuousClock.Instant) -> String? {
        guard let clients = agentClients(agent: agent, deadline: deadline) else { return nil }
        let candidates = clients.filter { $0.ssh == ssh }.sorted { $0.startTime > $1.startTime }
        guard let newest = candidates.first else { return nil }
        let recent = candidates.filter { newest.startTime - $0.startTime < Self.recentWindow }

        // Several clients that started together are ambiguous unless they all read the same, such as
        // two signatures from one rebase.
        var label: String?
        for client in recent {
            guard let next = self.label(startingAt: client.pid, deadline: deadline) else { return nil }
            if let label, label != next { return nil }
            label = next
        }
        return label
    }

    /// The agent's connected clients, or `nil` if the budget ran out before the scan finished. With `agent`,
    /// only that gpg-agent's clients count, and none if the PID doesn't name one of the user's gpg-agents.
    func agentClients(agent: Int32? = nil, deadline: ContinuousClock.Instant) -> [AgentClient]? {
        let agents: [Int32]
        if let agent {
            guard isAgent(processes.record(agent)) else { return [] }
            agents = [agent]
        } else {
            agents = agentPIDs()
        }
        // Peer protocol control block → whether the client came in on the ssh socket.
        var peers: [UInt64: Bool] = [:]
        for agent in agents {
            for socket in processes.unixSockets(agent) where socket.peerPCB != 0 && Self.isAgentSocket(socket.path) {
                peers[socket.peerPCB] = socket.path.hasSuffix(".ssh")
            }
        }
        guard !peers.isEmpty else { return [] }

        var clients: [AgentClient] = []
        for pid in processes.processes(uid: uid) where !agents.contains(pid) {
            guard ContinuousClock.now < deadline else { return nil }
            guard let ssh = processes.unixSockets(pid).lazy.compactMap({ peers[$0.pcb] }).first,
                  let record = processes.record(pid), record.uid == uid else { continue }
            clients.append(AgentClient(pid: pid, startTime: record.startTime, ssh: ssh))
        }
        return clients
    }

    /// gpg-agent's sockets are `S.gpg-agent`, `S.gpg-agent.ssh`, `S.gpg-agent.extra` and
    /// `S.gpg-agent.browser`. An accepted connection carries its listener's path.
    static func isAgentSocket(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("S.gpg-agent")
    }

    /// The user's gpg-agent processes, for a proxy that doesn't report its agent. The cached PIDs are reused while they still name a gpg-agent.
    func agentPIDs() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        if !cachedAgents.isEmpty, cachedAgents.allSatisfy({ isAgent(processes.record($0)) }) {
            return cachedAgents
        }
        cachedAgents = processes.processes(uid: uid).filter { isAgent(processes.record($0)) }
        return cachedAgents
    }

    private func isAgent(_ record: ProcessRecord?) -> Bool {
        guard let record else { return false }
        return record.uid == uid && record.name == "gpg-agent"
    }

    // MARK: Pinentry prompts

    /// The label for a pinentry's prompt. A pinentry that gpg-agent started, directly or through a
    /// wrapper script, prompts for the agent's client: the owner, if it is connected to that agent.
    /// The owner value comes from whatever started the pinentry, so an owner that isn't the agent's
    /// client gives no label. A pinentry that no gpg-agent started returns what it reads to its parent,
    /// so the label names the parent and says that the prompt didn't come through gpg-agent.
    private func labelForPinentry(_ pid: Int32, owner: Int32?, deadline: ContinuousClock.Instant) -> String? {
        guard let record = processes.record(pid), record.uid == uid else { return nil }
        var current = record.ppid
        var agent: Int32?
        for _ in 0..<Self.maxChainLength where current > 1 {
            guard let parent = processes.record(current), parent.uid == uid else { break }
            if isAgentExecutable(current) {
                agent = current
                break
            }
            current = parent.ppid
        }
        guard let agent else {
            return chain(startingAt: record.ppid, deadline: deadline).map(ClientLabel.directPromptLabel)
        }
        guard let owner, owner != pid, processes.record(owner)?.uid == uid, isClient(owner, of: agent) else { return nil }
        return chain(startingAt: owner, deadline: deadline).flatMap(ClientLabel.promptLabel)
    }

    /// Whether `pid` runs gpg-agent, by its executable's path rather than its arguments.
    private func isAgentExecutable(_ pid: Int32) -> Bool {
        guard let record = processes.record(pid) else { return false }
        let link = ClientLabel.Link(name: record.name, argv: [], executable: processes.executablePath(pid))
        return ClientLabel.executableName(link) == "gpg-agent"
    }

    /// Whether `client` holds a connection to one of `agent`'s sockets.
    private func isClient(_ client: Int32, of agent: Int32) -> Bool {
        let peers = Set(processes.unixSockets(agent).lazy.filter { $0.peerPCB != 0 && Self.isAgentSocket($0.path) }.map(\.peerPCB))
        return processes.unixSockets(client).contains { peers.contains($0.pcb) }
    }

    // MARK: Labelling

    /// Walks from `pid` up through its parents and labels the chain. `nil` if `pid` is gone.
    func label(startingAt pid: Int32, deadline: ContinuousClock.Instant) -> String? {
        chain(startingAt: pid, deadline: deadline).flatMap(ClientLabel.label)
    }

    /// `pid` and its parents, nearest first, up to `maxChainLength`. Empty if `pid` is gone; `nil` if the
    /// budget ran out.
    func chain(startingAt pid: Int32, deadline: ContinuousClock.Instant) -> [ClientLabel.Link]? {
        var chain: [ClientLabel.Link] = []
        var current = pid
        while chain.count < Self.maxChainLength, current > 1 {
            // A chain cut short could miss the git parent and name the wrong thing.
            guard ContinuousClock.now < deadline else { return nil }
            guard let record = processes.record(current), record.uid == uid else { break }
            let argv = processes.arguments(current)?.argv ?? []
            chain.append(ClientLabel.Link(
                name: record.name,
                argv: argv,
                cwd: processes.currentDirectory(current),
                executable: processes.executablePath(current)
            ))
            current = record.ppid
        }
        return chain
    }
}
