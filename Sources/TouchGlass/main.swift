import AppKit
import TouchGlassCore
import TouchGlassPanel

let usage = """
    Usage: TouchGlass
           TouchGlass --demo [scenario] [options]

    Without arguments, TouchGlass runs as the host: it listens for touchglass-pinentry and
    touchglass-scdaemon on its socket and shows the panel for their prompts and card operations.

    --demo shows the panel with scripted states. No gpg and no card are involved. Without a
    scenario, it runs all of them in turn.

    Scenarios:
    \(DemoScenario.allCases.map { "  \($0.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))\($0.summary)" }.joined(separator: "\n"))

    Demo options:
      --touch-after <seconds>   Simulate the touch after this many seconds (default 4).
      --auto-submit <seconds>   Submit PIN, passphrase and confirm prompts by themselves.
      --slow <factor>           Slow panel animations down by this factor, to review them.
      --no-controls             Hide the demo controls window.
      --focus-report            Print whether the PIN panel took key focus.
      --appearance <look>       readable (default) or smoked.
      --client <label>          Show this label for what asked, instead of each scenario's sample.
      --no-client               Hide the client line, as show-client = no does.
      --color-scheme <scheme>   light or dark, instead of the system appearance.

    The host reads its settings from host.conf in its support directory:
    appearance = readable|smoked, show-client = yes|no, touch-timeout = <seconds>.

    In the demo, any text in the PIN field continues. Press Space with the demo controls
    window focused, or click Simulate Touch, to touch.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
    exit(64)
}

/// Parses the command line. Exits with usage on errors.
func parseArguments() -> (DemoScenario, DemoOptions) {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var options = DemoOptions()
    var scenario: DemoScenario?

    func number(after flag: String) -> Double {
        guard !arguments.isEmpty, let value = Double(arguments.removeFirst()), value >= 0 else {
            fail("\(flag) needs a number.")
        }
        return value
    }

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--demo":
            scenario = .all
            if let next = arguments.first, !next.hasPrefix("--") {
                arguments.removeFirst()
                guard let parsed = DemoScenario(rawValue: next) else { fail("Unknown scenario: \(next)") }
                scenario = parsed
            }
        case "--color-scheme":
            switch arguments.isEmpty ? "" : arguments.removeFirst() {
            case "light": options.colorScheme = .aqua
            case "dark": options.colorScheme = .darkAqua
            default: fail("--color-scheme needs light or dark.")
            }
        case "--touch-after": options.touchAfter = number(after: argument)
        case "--auto-submit": options.autoSubmitAfter = number(after: argument)
        case "--slow": options.animationScale = max(1, number(after: argument))
        case "--no-controls": options.showControls = false
        case "--focus-report": options.focusReport = true
        case "--appearance":
            guard !arguments.isEmpty, let appearance = PanelAppearance(rawValue: arguments.removeFirst()) else {
                fail("--appearance needs smoked or readable.")
            }
            options.settings.appearance = appearance
        case "--client":
            guard !arguments.isEmpty else { fail("--client needs a label.") }
            options.client = arguments.removeFirst()
        case "--no-client": options.settings.showClient = false
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("Unknown argument: \(argument)")
        }
    }

    guard let scenario else { fail("Nothing to do.") }
    return (scenario, options)
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().first == "--host" {
    MainActor.assumeIsolated {
        runHost()
    }
    app.run()
    exit(0)
}

let (scenario, options) = parseArguments()
if let colorScheme = options.colorScheme {
    MainActor.assumeIsolated { app.appearance = NSAppearance(named: colorScheme) }
}

MainActor.assumeIsolated {
    let runner = DemoRunner(options: options)
    Task { @MainActor in
        await runner.run(scenario)
        NSApp.terminate(nil)
    }
    withExtendedLifetime(runner) {
        app.run()
    }
}
