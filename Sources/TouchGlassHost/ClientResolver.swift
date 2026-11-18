import Foundation

/// What the host knows about the process behind a card operation when it asks for a label.
public enum ClientQuery: Sendable, Equatable {
    /// The client PID from the agent's `OPTION owner`, which a pinentry request carries.
    case owner(Int32)
    /// One of the agent's connected clients: an ssh client for an SSH login, any other client for a
    /// signature or decryption.
    case agentClient(ssh: Bool)

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
            return label(startingAt: pid, deadline: deadline)
        case .agentClient(let ssh):
            return labelForAgentClient(ssh: ssh, deadline: deadline)
        }
    }

    // MARK: Choosing the client

    struct AgentClient: Equatable {
        var pid: Int32
        var startTime: Double
        var ssh: Bool
    }

    private func labelForAgentClient(ssh: Bool, deadline: ContinuousClock.Instant) -> String? {
        guard let clients = agentClients(deadline: deadline) else { return nil }
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

    /// The agent's connected clients, or `nil` if the budget ran out before the scan finished.
    func agentClients(deadline: ContinuousClock.Instant) -> [AgentClient]? {
        let agents = agentPIDs()
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

    /// The user's gpg-agent processes. The cached PIDs are reused while they still name a gpg-agent.
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

    // MARK: Labelling

    /// Walks from `pid` up through its parents and labels the chain. `nil` if `pid` is gone.
    func label(startingAt pid: Int32, deadline: ContinuousClock.Instant) -> String? {
        var chain: [ClientLabel.Link] = []
        var current = pid
        while chain.count < Self.maxChainLength, current > 1 {
            // A chain cut short could miss the git parent and name the wrong thing.
            guard ContinuousClock.now < deadline else { return nil }
            guard let record = processes.record(current), record.uid == uid else { break }
            let argv = processes.arguments(current)?.argv ?? []
            chain.append(ClientLabel.Link(name: record.name, argv: argv, cwd: processes.currentDirectory(current)))
            current = record.ppid
        }
        return ClientLabel.label(chain: chain)
    }
}
