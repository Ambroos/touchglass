import Foundation
import TouchGlassCore
import TouchGlassIPC

/// The panel as the host session drives it. `PanelController` conforms in the app; tests use a recorder.
@MainActor
public protocol PanelDriving: AnyObject {
    func send(_ event: PanelEvent)
    func shakeField()
    /// Installs the callbacks for the panel's controls.
    func setActions(_ actions: PanelActions)
}

/// Connects the socket server, the coordinator and the panel on the main actor.
@MainActor
public final class HostSession {
    public private(set) var coordinator: HostCoordinator
    private let server: HostServer
    private let panel: PanelDriving
    /// Names what asked for an operation. `nil` turns client labels off.
    private let resolver: ClientResolving?
    /// Lookups run one at a time, off the main thread.
    private let resolverQueue = DispatchQueue(label: "TouchGlass client lookup", qos: .userInitiated)
    /// Runs after the session stopped for `HostOutput.exit`. The app exits the process here.
    private let onRetire: @MainActor () -> Void
    /// `cards.conf`; nil keeps learned policies in memory only.
    private let policyStore: CardPolicyStore?
    /// Asks gpg-agent for touch policies; nil never asks.
    private let policyQuery: CardPolicyQuerying?
    /// Queries run one at a time, off the main thread.
    private let policyQueue = DispatchQueue(label: "TouchGlass touch policy query", qos: .utility)
    private let log = TouchGlassLog(.host)
    private var lastPanelLog: LogEvent?

    /// - Parameters:
    ///   - version: The release this host runs; see `HostCoordinator.version`.
    ///   - onRetire: Called after the session stopped because a helper of a later release connected.
    public init(
        server: HostServer,
        panel: PanelDriving,
        resolver: ClientResolving? = nil,
        touchTimeout: TimeInterval? = nil,
        touchCache: TouchCacheSetting = .auto,
        policyStore: CardPolicyStore? = nil,
        policyQuery: CardPolicyQuerying? = nil,
        version: String? = nil,
        retireAfterIdle: TimeInterval = HostCoordinator.defaultRetireAfterIdle,
        onRetire: @escaping @MainActor () -> Void = {}
    ) {
        self.server = server
        self.panel = panel
        self.resolver = resolver
        self.onRetire = onRetire
        self.policyStore = policyStore
        self.policyQuery = policyQuery
        coordinator = HostCoordinator(touchTimeout: touchTimeout, touchCache: touchCache, version: version)
        if let policyStore { coordinator.loadPolicies(policyStore.load()) }
        coordinator.retireAfterIdle = retireAfterIdle

        var actions = PanelActions()
        actions.submitSecret = { [weak self] secret in self?.user(.submit(secret)) }
        actions.cancel = { [weak self] in self?.user(.cancel) }
        actions.confirm = { [weak self] in self?.user(.confirm) }
        actions.hide = { [weak self] in self?.user(.hide) }
        actions.dismiss = { [weak self] in self?.user(.dismiss) }
        panel.setActions(actions)
    }

    public func start() {
        log(.hostStarted(version: coordinator.version, touchTimeout: coordinator.touchTimeout, touchCache: coordinator.touchCache.fixedSeconds))
        server.start(
            onMessage: { [weak self] message, connection in self?.receive(message, from: connection) },
            onClose: { [weak self] connection in self?.closed(connection) }
        )
    }

    public func stop() {
        server.stop()
    }

    public func receive(_ message: IPCMessage, from connection: ConnectionID) {
        // `touchglass card` may have written the file meanwhile.
        if case .opStart = message, let policyStore, let cards = policyStore.reloadIfChanged() {
            coordinator.loadPolicies(cards)
        }
        perform(coordinator.handle(message, from: connection, now: Date()))
    }

    public func closed(_ connection: ConnectionID) {
        log(.connectionClosed(id: connection))
        perform(coordinator.connectionClosed(connection, now: Date()))
    }

    public func user(_ action: UserAction) {
        perform(coordinator.handle(action))
    }

    private func perform(_ outputs: [HostOutput]) {
        for event in coordinator.takeLog() { log(event) }
        for output in outputs {
            switch output {
            case .panel(let event):
                // A label that fills in re-sends the same state; log changes of state only.
                if let entry = Self.logEvent(for: event), entry != lastPanelLog {
                    lastPanelLog = entry
                    log(entry)
                }
                panel.send(event)
            case .shakeField:
                panel.shakeField()
            case .reply(let connection, let message):
                server.send(message, to: connection)
            case .schedule(let delay, let timer):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.perform(self.coordinator.fire(timer, now: Date()))
                }
            case .resolveClient(let subject, let query):
                guard let resolver else { continue }
                resolverQueue.async { [weak self] in
                    let label = resolver.label(for: query)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.perform(self.coordinator.clientResolved(subject, label: label))
                    }
                }
            case .queryCardPolicy(let serial, let gnupg):
                guard let policyQuery else { continue }
                policyQueue.async { [weak self] in
                    let slots = policyQuery.query(serial: serial, gnupg: gnupg)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.perform(self.coordinator.policyQueried(serial: serial, slots: slots, now: Date()))
                    }
                }
            case .saveCardPolicies(let cards):
                policyStore?.save(cards)
            case .exit:
                // Removes the socket first, so a helper that connects from now on starts the installed host.
                stop()
                onRetire()
                return
            }
        }
    }

    /// The panel event as the log names it: the state's name, never its text.
    static func logEvent(for event: PanelEvent) -> LogEvent? {
        switch event {
        case .show(let state):
            let name: PanelStateName = switch state {
            case .pinEntry: .pinEntry
            case .verifying: .verifying
            case .passphrase: .passphrase
            case .touchWait: .touchWait
            case .success: .success
            case .failure: .failure
            case .confirm: .confirm
            case .message: .message
            }
            return .panelShow(name)
        case .dismiss: return .panelDismiss
        case .userClosed: return .panelUserClosed
        case .userHid: return .panelUserHid
        default: return nil
        }
    }
}
