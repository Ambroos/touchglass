import CoreGraphics
import Foundation
import ScreenshotMatte

let usage = """
    Usage: touchglass-matte --white <png> --black <png> --out <png> [options]

    Recovers a transparent PNG of the panel from two captures of the same region, one over a
    white backdrop and one over a black backdrop, by difference matting.

    Options:
      --padding <pixels>      Crop to the visible panel and its shadow plus this margin. Without
                              it, the output keeps the size of the captures.
      --white-out <png>       Also write the white capture, cropped the same way.
      --black-out <png>       Also write the black capture, cropped the same way.
      --composite-out <png>   Also write the matte over mid-grey, to check edges for fringes.
      --skip-edge-check       Don't require plain backdrop along the edges of the captures.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("touchglass-matte: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var paths: [String: String] = [:]
var padding: Int?
var edgeCheck = true
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--white", "--black", "--out", "--white-out", "--black-out", "--composite-out":
        guard !arguments.isEmpty else { fail("\(argument) needs a path.") }
        paths[argument] = arguments.removeFirst()
    case "--padding":
        guard let value = arguments.isEmpty ? nil : Int(arguments.removeFirst()), value >= 0 else { fail("--padding needs a number of pixels.") }
        padding = value
    case "--skip-edge-check": edgeCheck = false
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown argument \(argument)\n\n\(usage)")
    }
}
guard let whitePath = paths["--white"], let blackPath = paths["--black"], let outPath = paths["--out"] else {
    fail("--white, --black and --out are required.\n\n\(usage)")
}

do {
    let (white, space) = try MatteIO.read(URL(fileURLWithPath: whitePath))
    let (black, _) = try MatteIO.read(URL(fileURLWithPath: blackPath))
    if edgeCheck { try DifferenceMatte.checkBackdrop(white: white, black: black) }
    var (matte, report) = try DifferenceMatte.extract(white: white, black: black)
    var crop = PixelRect(x: 0, y: 0, width: white.width, height: white.height)
    if let padding {
        guard let bounds = DifferenceMatte.bounds(of: matte, padding: padding) else { fail("the matte is empty: the captures are identical.") }
        crop = bounds
        matte = matte.cropped(to: crop)
    }
    try MatteIO.writePNG(matte, space: space, to: URL(fileURLWithPath: outPath))
    if let path = paths["--white-out"] {
        try MatteIO.writePNG(white.cropped(to: crop), space: space, to: URL(fileURLWithPath: path), opaque: true)
    }
    if let path = paths["--black-out"] {
        try MatteIO.writePNG(black.cropped(to: crop), space: space, to: URL(fileURLWithPath: path), opaque: true)
    }
    if let path = paths["--composite-out"] {
        try MatteIO.writePNG(matte.composited(over: (0.5, 0.5, 0.5)), space: space, to: URL(fileURLWithPath: path), opaque: true)
    }
    print(String(
        format: "%@: %d×%d px, composite error max %.1f mean %.2f (8-bit steps), %d inverted channel values",
        outPath, matte.width, matte.height, report.maxError * 255, report.meanError * 255, report.inverted
    ))
} catch {
    fail("\(error)")
}
