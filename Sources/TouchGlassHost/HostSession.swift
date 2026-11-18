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
    public private(set) var coordinator = HostCoordinator()
    private let server: HostServer
    private let panel: PanelDriving

    public init(server: HostServer, panel: PanelDriving) {
        self.server = server
        self.panel = panel

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
            }
        }
    }
}
