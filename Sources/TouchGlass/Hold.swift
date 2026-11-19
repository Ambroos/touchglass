import AppKit
import ImageIO
import UniformTypeIdentifiers
import TouchGlassCore
import TouchGlassPanel

/// Panel states that `--hold` shows for screenshots.
enum HoldState: String, CaseIterable {
    case pinEntry = "pin-entry"
    case pinRetry = "pin-retry"
    case touch
    case ssh
    case success
    case wrongPIN = "wrong-pin"
    case timeout

    var summary: String {
        switch self {
        case .pinEntry: "PIN entry for a signature, with a few characters typed"
        case .pinRetry: "PIN entry with 2 attempts left, with a few characters typed"
        case .touch: "touch wait for a signature, countdown stopped at 12 seconds"
        case .ssh: "touch wait for an SSH login, countdown stopped at 12 seconds"
        case .success: "signed"
        case .wrongPIN: "wrong PIN"
        case .timeout: "touch timed out"
        }
    }

    /// The sample label for what asked; `nil` for states that show none.
    var client: String? {
        switch self {
        case .pinEntry, .pinRetry: "git commit · touchglass"
        case .touch: "git push origin · touchglass"
        case .ssh: "ssh github.com"
        case .success, .wrongPIN, .timeout: nil
        }
    }
}

/// A solid colour for the window behind the panel during screenshots.
struct Backdrop {
    var red: Double
    var green: Double
    var blue: Double

    /// `white`, `black` or `#rrggbb`.
    init?(_ text: String) {
        switch text.lowercased() {
        case "white": (red, green, blue) = (1, 1, 1)
        case "black": (red, green, blue) = (0, 0, 0)
        default:
            guard text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }
    }

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// Shows one panel state and keeps it on screen until the process is stopped, for screenshots.
///
/// The panel holds key status, so the glass renders its key look, and the countdown stays at one
/// value. With a backdrop, a borderless window of one colour covers the panel's screen one level
/// below the panel, so the glass refracts nothing but that colour. When the panel has settled, the
/// runner prints one line to standard output:
///
///     ready window=<number> x=<x> y=<y> width=<w> height=<h> scale=<s> key=<true|false>
///
/// The frame is the panel window's, in points, in screen coordinates with the origin at the top
/// left of the main display.
@MainActor
final class HoldRunner {
    private static let serial = "12345678"
    /// Seconds into the touch step at which the countdown stops: "12 seconds left", calm phase, mid-ripple.
    private static let frozenElapsed: TimeInterval = 3.0
    /// The entrance takes about 0.5 s; give the glass and SwiftUI time to settle beyond that.
    private static let settle: TimeInterval = 1.5

    private let controller: PanelController
    private let options: DemoOptions
    private var backdropWindow: NSWindow?

    init(options: DemoOptions) {
        self.options = options
        controller = PanelController(animationScale: 1, settings: options.settings)
        controller.holdsState = true
    }

    func run(_ hold: HoldState) async {
        if options.capturePath != nil { checkScreen() }
        let client = options.client ?? hold.client
        let state = makeState(hold, client: client)
        controller.send(.show(state))
        if let backdrop = options.backdrop { showBackdrop(backdrop) }

        try? await Task.sleep(for: .seconds(Self.settle))
        controller.window.makeKey()
        try? await Task.sleep(for: .seconds(0.2))
        printReady()
        if let path = options.capturePath { capture(to: path) }
        // Stay until the process is stopped.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func makeState(_ hold: HoldState, client: String?) -> PanelState {
        switch hold {
        case .pinEntry, .pinRetry:
            controller.model.sampleSecretLength = 6
            let attempts = hold == .pinRetry ? 2 : nil
            return .pinEntry(PinRequest(operation: .sign, cardSerial: Self.serial, attemptsLeft: attempts, minimumLengthOverride: 1, client: client))
        case .touch, .ssh:
            let now = Date()
            controller.model.frozenClock = now.addingTimeInterval(Self.frozenElapsed)
            let operation: OperationKind = hold == .ssh ? .sshLogin : .sign
            return .touchWait(TouchWait.detected(operation: operation, cardSerial: Self.serial, now: now, client: client))
        case .success:
            return .success(.sign)
        case .wrongPIN:
            return .failure(.wrongPIN)
        case .timeout:
            return .failure(.touchTimeout(seconds: Int(TouchTiming.cardTimeout)))
        }
    }

    private func showBackdrop(_ backdrop: Backdrop) {
        let panel = controller.window
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let window = BackdropWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = backdrop.color
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        backdropWindow = window
    }

    private func printReady() {
        let window = controller.window
        let frame = window.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = primaryHeight - frame.maxY
        let scale = window.backingScaleFactor
        print("ready window=\(window.windowNumber) x=\(Int(frame.minX)) y=\(Int(top)) width=\(Int(frame.width)) height=\(Int(frame.height)) scale=\(scale) key=\(window.isKeyWindow)")
    }
}

extension HoldRunner {
    /// Writes the panel window's region, with everything this app shows below it, as a PNG at the
    /// screen's pixel scale, then prints `captured <path>`.
    ///
    /// A process may capture its own windows without Screen Recording permission. Other apps'
    /// windows are left out, which changes nothing here: the backdrop covers everything below
    /// the panel. `CGWindowListCreateImage` is unavailable to Swift in the macOS 15 and later SDKs
    /// but still exported, so it is looked up at run time; ScreenCaptureKit would need the
    /// permission even for this app's own windows.
    /// A locked screen or a sleeping display draws nothing, so captures come out blank.
    private func checkScreen() {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            stop("The screen is locked, so there is nothing to capture. Unlock the Mac and run again.")
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            stop("The display is asleep. Wake it and run again.")
        }
    }

    private func stop(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    private func capture(to path: String) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            stop("CGWindowListCreateImage is missing on this system.")
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let window = controller.window
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = window.frame
        let rect = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowListOption([.optionOnScreenBelowWindow, .optionIncludingWindow]).rawValue
        let imageOptions = CGWindowImageOption.bestResolution.rawValue
        guard let image = create(rect, options, CGWindowID(window.windowNumber), imageOptions)?.takeRetainedValue() else {
            stop("Capturing the panel failed.")
        }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            stop("Can't write \(path).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { stop("Can't write \(path).") }
        print("captured \(path) \(image.width)x\(image.height)")
    }
}

/// Never takes key or main status, so the panel keeps key status above it.
private final class BackdropWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
