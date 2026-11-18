import AppKit
import TouchGlassCore
import TouchGlassHost
import TouchGlassIPC
import TouchGlassPanel

extension PanelController: PanelDriving {
    public func setActions(_ actions: PanelActions) {
        self.actions = actions
    }
}

@MainActor private var hostSession: HostSession?

/// Starts listening on the host socket. Exits quietly if another host already answers there.
@MainActor
func runHost() {
    let server: HostServer
    do {
        server = try HostServer()
    } catch IPCError.addressInUse {
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("TouchGlass: cannot listen on \(IPCPaths.hostSocket): \(error)\n".utf8))
        exit(1)
    }
    let session = HostSession(server: server, panel: PanelController())
    session.start()
    hostSession = session

    // Remove the socket on a normal quit, so helpers fall back at once instead of timing out.
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { hostSession?.stop() }
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

@MainActor private var signalSources: [DispatchSourceSignal] = []
