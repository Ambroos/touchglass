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

    /// - Parameters:
    ///   - version: The release this host runs; see `HostCoordinator.version`.
    ///   - onRetire: Called after the session stopped because a helper of a later release connected.
    public init(
        server: HostServer,
        panel: PanelDriving,
        resolver: ClientResolving? = nil,
        touchTimeout: TimeInterval? = nil,
        version: String? = nil,
        retireAfterIdle: TimeInterval = HostCoordinator.defaultRetireAfterIdle,
        onRetire: @escaping @MainActor () -> Void = {}
    ) {
        self.server = server
        self.panel = panel
        self.resolver = resolver
        self.onRetire = onRetire
        coordinator = HostCoordinator(touchTimeout: touchTimeout, version: version)
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
        server.start(
            onMessage: { [weak self] message, connection in self?.receive(message, from: connection) },
            onClose: { [weak self] connection in self?.closed(connection) }
        )
    }

    public func stop() {
        server.stop()
    }

    public func receive(_ message: IPCMessage, from connection: ConnectionID) {
        perform(coordinator.handle(message, from: connection, now: Date()))
    }

    public func closed(_ connection: ConnectionID) {
        perform(coordinator.connectionClosed(connection))
    }

    public func user(_ action: UserAction) {
        perform(coordinator.handle(action))
    }

    private func perform(_ outputs: [HostOutput]) {
        for output in outputs {
            switch output {
            case .panel(let event):
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
            case .exit:
                // Removes the socket first, so a helper that connects from now on starts the installed host.
                stop()
                onRetire()
                return
            }
        }
    }
}
