import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotMatte

@Suite struct MatteTests {
    /// A 40 × 30 image: transparent, with a soft shadow ramp, an opaque coloured block and a semi-transparent grey pane.
    private func sample() -> RGBAImage {
        var image = RGBAImage(width: 40, height: 30, fill: (0, 0, 0, 0))
        for y in 5..<25 {
            for x in 5..<35 {
                // Shadow: black with alpha falling off towards the edge.
                let edge = min(x - 5, 34 - x, y - 5, 24 - y)
                image[x, y] = (0, 0, 0, Float(edge + 1) / 40)
            }
        }
        for y in 10..<20 {
            for x in 10..<20 { image[x, y] = (0.9, 0.3, 0.1, 1) }
            for x in 20..<30 { image[x, y] = (0.8, 0.85, 0.9, 0.55) }
        }
        return image
    }

    /// Rounds to 8-bit, as a PNG capture does.
    private func quantized(_ image: RGBAImage) -> RGBAImage {
        var out = image
        out.pixels = image.pixels.map { ($0 * 255).rounded() / 255 }
        return out
    }

    @Test func recoversShapeFromWhiteAndBlack() throws {
        let original = sample()
        let white = quantized(original.composited(over: (1, 1, 1)))
        let black = quantized(original.composited(over: (0, 0, 0)))
        let (matte, report) = try DifferenceMatte.extract(white: white, black: black)

        for y in 0..<original.height {
            for x in 0..<original.width {
                let expected = original[x, y], got = matte[x, y]
                #expect(abs(got.a - expected.a) < 2.0 / 255, "alpha at \(x),\(y)")
                // Colour is meaningless where nearly transparent; check it where it carries weight.
                if expected.a > 0.2 {
                    #expect(abs(got.r - expected.r) < 3.0 / 255 / expected.a, "red at \(x),\(y)")
                    #expect(abs(got.g - expected.g) < 3.0 / 255 / expected.a, "green at \(x),\(y)")
                    #expect(abs(got.b - expected.b) < 3.0 / 255 / expected.a, "blue at \(x),\(y)")
                }
            }
        }
        #expect(report.maxError < 2.0 / 255)
        #expect(report.inverted == 0)
    }

    @Test func recompositesOverOtherBackgrounds() throws {
        let original = sample()
        let (matte, _) = try DifferenceMatte.extract(
            white: quantized(original.composited(over: (1, 1, 1))),
            black: quantized(original.composited(over: (0, 0, 0)))
        )
        let expected = original.composited(over: (0.2, 0.6, 0.4))
        let got = matte.composited(over: (0.2, 0.6, 0.4))
        let worst = zip(expected.pixels, got.pixels).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 3.0 / 255)
    }

    @Test func boundsCoverTheVisiblePixelsWithPadding() {
        let image = sample()
        #expect(DifferenceMatte.bounds(of: image, padding: 2) == PixelRect(x: 3, y: 3, width: 34, height: 24))
        #expect(DifferenceMatte.bounds(of: image, padding: 10) == PixelRect(x: 0, y: 0, width: 40, height: 30))
        #expect(DifferenceMatte.bounds(of: RGBAImage(width: 4, height: 4, fill: (1, 1, 1, 0))) == nil)
    }

    @Test func reportsAChangeBetweenCaptures() throws {
        let original = sample()
        var moved = original
        // The opaque block moves one pixel between the captures, as an animation still running would.
        for y in 10..<20 { moved[9, y] = (0.9, 0.3, 0.1, 1); moved[19, y] = (0.8, 0.85, 0.9, 0.55) }
        let (_, report) = try DifferenceMatte.extract(
            white: original.composited(over: (1, 1, 1)),
            black: moved.composited(over: (0, 0, 0))
        )
        #expect(report.maxError > 20.0 / 255)
    }

    @Test func edgeCheckRejectsAPanelTouchingTheCrop() {
        let original = sample()
        let white = original.composited(over: (1, 1, 1))
        let black = original.composited(over: (0, 0, 0))
        #expect(throws: Never.self) { try DifferenceMatte.checkBackdrop(white: white, black: black) }
        let tight = PixelRect(x: 8, y: 8, width: 24, height: 14)
        #expect(throws: MatteError.self) { try DifferenceMatte.checkBackdrop(white: white.cropped(to: tight), black: black.cropped(to: tight)) }
    }

    @Test func mismatchedSizesThrow() {
        let a = RGBAImage(width: 2, height: 2, fill: (1, 1, 1, 1))
        let b = RGBAImage(width: 3, height: 2, fill: (0, 0, 0, 1))
        #expect(throws: MatteError.self) { try DifferenceMatte.extract(white: a, black: b) }
    }

    @Test func pngRoundTripKeepsStraightAlpha() throws {
        let original = quantized(sample())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("matte-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try MatteIO.writePNG(original, space: CGColorSpace(name: CGColorSpace.sRGB)!, to: url)
        let (read, _) = try MatteIO.read(url)
        // Reading goes through a premultiplied context, so colour loses precision as alpha falls.
        for y in 0..<original.height {
            for x in 0..<original.width {
                let expected = original[x, y], got = read[x, y]
                #expect(abs(got.a - expected.a) < 0.5 / 255)
                if expected.a > 0.5 { #expect(abs(got.r - expected.r) < 2.0 / 255) }
            }
        }
    }
}
