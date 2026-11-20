import AppKit
import TouchGlassCore

// touchglass-screenshots: shows one panel state for scripts/screenshots.sh. A developer tool; it is
// not part of TouchGlass.app, because its capture looks up a CoreGraphics function that the SDK no
// longer declares.

let usage = """
    Usage: touchglass-screenshots <state> [options]

    Shows one panel state and keeps it until the process is stopped, for screenshots.
    The panel holds key focus and makes no sound; the touch countdown stays at 12 seconds.
    When the panel has settled, it prints a line with the panel window's frame.

    States:
    \(HoldState.allCases.map { "  \($0.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))\($0.summary)" }.joined(separator: "\n"))

    Options:
      --appearance <look>       readable (default) or smoked.
      --color-scheme <scheme>   light or dark, instead of the system appearance.
      --client <label>          Show this label for what asked, instead of the state's sample.
      --no-client               Hide the client line, as show-client = no does.
      --backdrop <colour>       white, black or #rrggbb behind the panel.
      --capture <png>           Write the panel's region to this PNG when ready.
      --burst <dir>             Instead, capture the panel's region about 60 times a second from
                                the moment it shows, for 2 seconds, as frame-NNN.png in <dir>
                                (times in times.txt), then exit. For checking the entrance.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
    exit(64)
}

/// Parses the command line. Exits with usage on errors.
func parseArguments() -> (HoldState, HoldOptions) {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var options = HoldOptions()
    var state: HoldState?

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--backdrop":
            guard !arguments.isEmpty, let backdrop = Backdrop(arguments.removeFirst()) else {
                fail("--backdrop needs white, black or #rrggbb.")
            }
            options.backdrop = backdrop
        case "--capture":
            guard !arguments.isEmpty else { fail("--capture needs a path.") }
            options.capturePath = arguments.removeFirst()
        case "--burst":
            guard !arguments.isEmpty else { fail("--burst needs a directory.") }
            options.burstDirectory = arguments.removeFirst()
        case "--color-scheme":
            switch arguments.isEmpty ? "" : arguments.removeFirst() {
            case "light": options.colorScheme = .aqua
            case "dark": options.colorScheme = .darkAqua
            default: fail("--color-scheme needs light or dark.")
            }
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
            guard state == nil, !argument.hasPrefix("-") else { fail("Unknown argument: \(argument)") }
            guard let parsed = HoldState(rawValue: argument) else { fail("Unknown state: \(argument)") }
            state = parsed
        }
    }

    guard let state else { fail("Name a state.") }
    return (state, options)
}

setvbuf(stdout, nil, _IOLBF, 0)
let (state, options) = parseArguments()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if let colorScheme = options.colorScheme {
    MainActor.assumeIsolated { app.appearance = NSAppearance(named: colorScheme) }
}

MainActor.assumeIsolated {
    let runner = HoldRunner(options: options)
    Task { @MainActor in await runner.run(state) }
    withExtendedLifetime(runner) {
        app.run()
    }
}
