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
    let settings = HostSettings.load(path: IPCPaths.supportDirectory + "/host.conf")
    let session = HostSession(
        server: server,
        panel: PanelController(settings: settings),
        resolver: settings.showClient ? ClientResolver() : nil,
        touchTimeout: settings.touchTimeout,
        touchCache: settings.touchCache,
        policyStore: CardPolicyStore(),
        policyQuery: GnuPGCardPolicyQuery(),
        // Read now: after brew upgrade, the bundle path shows the next release's Info.plist.
        version: BuildInfo.version,
        onRetire: { exit(0) }
    )
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
