import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image as floating-point RGBA, 0 to 1, row by row from the top. Alpha is straight, not premultiplied.
public struct RGBAImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// `width * height * 4` values: red, green, blue, alpha.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: (Float, Float, Float, Float)) {
        self.init(width: width, height: height, pixels: Array([fill.0, fill.1, fill.2, fill.3].repeated(width * height)))
    }

    public subscript(x: Int, y: Int) -> (r: Float, g: Float, b: Float, a: Float) {
        get {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    /// The part of the image inside `rect`, which must lie within the image.
    public func cropped(to rect: PixelRect) -> RGBAImage {
        var out = [Float]()
        out.reserveCapacity(rect.width * rect.height * 4)
        for y in rect.y..<(rect.y + rect.height) {
            let start = (y * width + rect.x) * 4
            out.append(contentsOf: pixels[start..<(start + rect.width * 4)])
        }
        return RGBAImage(width: rect.width, height: rect.height, pixels: out)
    }

    /// This image drawn over an opaque colour.
    public func composited(over background: (Float, Float, Float)) -> RGBAImage {
        var out = self
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[p + 3]
            out.pixels[p] = pixels[p] * a + background.0 * (1 - a)
            out.pixels[p + 1] = pixels[p + 1] * a + background.1 * (1 - a)
            out.pixels[p + 2] = pixels[p + 2] * a + background.2 * (1 - a)
            out.pixels[p + 3] = 1
        }
        return out
    }
}

private extension Array {
    func repeated(_ count: Int) -> [Element] {
        var out = [Element]()
        out.reserveCapacity(self.count * count)
        for _ in 0..<count { out.append(contentsOf: self) }
        return out
    }
}

public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// How well one alpha per pixel explains the two captures.
public struct MatteReport: Equatable, Sendable {
    /// The largest difference, over all pixels and channels, between a capture and the matte composited over that capture's background.
    public var maxError: Float
    /// The mean of that difference.
    public var meanError: Float
    /// Pixels that are darker over white than over black, beyond rounding. Many of them mean the panel changed between the captures.
    public var inverted: Int
}

public enum MatteError: Error, CustomStringConvertible {
    case sizeMismatch(white: (Int, Int), black: (Int, Int))
    case backdropMissing(String)
    case unreadable(String)
    case unwritable(String)

    public var description: String {
        switch self {
        case .sizeMismatch(let white, let black):
            "The captures differ in size: white is \(white.0)×\(white.1), black is \(black.0)×\(black.1)."
        case .backdropMissing(let detail): "The backdrop is missing from the captures: \(detail)"
        case .unreadable(let path): "Can't read the image at \(path)."
        case .unwritable(let path): "Can't write a PNG to \(path)."
        }
    }
}

public enum DifferenceMatte {
    /// Recovers a semi-transparent image from two captures of it, one over opaque white and one over opaque black.
    ///
    /// Over black a pixel is `c·a`; over white it is `c·a + (1 − a)`. So `1 − a` is white minus black. Each channel
    /// gives an estimate of alpha; the matte uses their mean, which keeps the composite error lowest when coloured
    /// glass passes the channels unequally. The colour is black divided by alpha. Pixels with alpha under half a
    /// step of 8-bit precision become fully transparent.
    public static func extract(white: RGBAImage, black: RGBAImage) throws -> (RGBAImage, MatteReport) {
        guard white.width == black.width, white.height == black.height else {
            throw MatteError.sizeMismatch(white: (white.width, white.height), black: (black.width, black.height))
        }
        var out = RGBAImage(width: white.width, height: white.height, fill: (0, 0, 0, 0))
        var maxError: Float = 0
        var totalError: Double = 0
        var inverted = 0
        let floor: Float = 0.5 / 255

        for p in stride(from: 0, to: white.pixels.count, by: 4) {
            var differences: [Float] = [0, 0, 0]
            for c in 0..<3 {
                let d = white.pixels[p + c] - black.pixels[p + c]
                if d < -2.0 / 255 { inverted += 1 }
                differences[c] = min(1, max(0, d))
            }
            let alpha = 1 - (differences[0] + differences[1] + differences[2]) / 3
            guard alpha >= floor else {
                // The matte says transparent; the error is the leftover difference from the white capture.
                for c in 0..<3 {
                    let error = abs(differences[c] - 1 + alpha)
                    maxError = max(maxError, error)
                    totalError += Double(error)
                }
                continue
            }
            for c in 0..<3 {
                let color = min(1, max(0, black.pixels[p + c] / alpha))
                out.pixels[p + c] = color
                // Composite the matte back over both backgrounds and compare.
                let overBlack = color * alpha
                let overWhite = overBlack + 1 - alpha
                let error = max(abs(overBlack - black.pixels[p + c]), abs(overWhite - white.pixels[p + c]))
                maxError = max(maxError, error)
                totalError += Double(error)
            }
            out.pixels[p + 3] = alpha
        }
        let count = Double(white.width * white.height * 3)
        return (out, MatteReport(maxError: maxError, meanError: count > 0 ? Float(totalError / count) : 0, inverted: inverted))
    }

    /// The smallest rectangle that holds every pixel with alpha above `threshold`, grown by `padding` on each side
    /// and kept inside the image. `nil` if no pixel passes.
    public static func bounds(of image: RGBAImage, threshold: Float = 2.0 / 255, padding: Int = 0) -> PixelRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[(y * image.width + x) * 4 + 3] > threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let x0 = max(0, minX - padding), y0 = max(0, minY - padding)
        let x1 = min(image.width - 1, maxX + padding), y1 = min(image.height - 1, maxY + padding)
        return PixelRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Checks that the edges of both captures show the plain backdrop, so the panel sits inside the crop and nothing
    /// else covers it. `tolerance` is per channel, 0 to 1.
    public static func checkBackdrop(white: RGBAImage, black: RGBAImage, tolerance: Float = 4.0 / 255) throws {
        func edge(_ image: RGBAImage) -> [(Int, Int)] {
            var points: [(Int, Int)] = []
            for x in 0..<image.width { points.append((x, 0)); points.append((x, image.height - 1)) }
            for y in 0..<image.height { points.append((0, y)); points.append((image.width - 1, y)) }
            return points
        }
        for (image, expected, name) in [(white, Float(1), "white"), (black, Float(0), "black")] {
            let wrong = edge(image).filter { point in
                let p = image[point.0, point.1]
                return abs(p.r - expected) > tolerance || abs(p.g - expected) > tolerance || abs(p.b - expected) > tolerance
            }
            if !wrong.isEmpty {
                let first = image[wrong[0].0, wrong[0].1]
                throw MatteError.backdropMissing(
                    "\(wrong.count) edge pixels of the \(name) capture are not \(name); the first, at \(wrong[0].0),\(wrong[0].1), is "
                        + String(format: "%.3f %.3f %.3f", first.r, first.g, first.b)
                        + ". Either the panel reaches the edge of the crop or another window covers the backdrop."
                )
            }
        }
    }
}

/// Reading and writing PNGs, keeping the capture's colour space so values are matted in the space the window server composited them in.
public enum MatteIO {
    public static func read(_ url: URL) throws -> (RGBAImage, CGColorSpace) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw MatteError.unreadable(url.path) }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw MatteError.unreadable(url.path) }
        var pixels = [Float](repeating: 0, count: bytes.count)
        for p in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[p + 3]) / 255
            for c in 0..<3 { pixels[p + c] = a > 0 ? min(1, Float(bytes[p + c]) / 255 / a) : 0 }
            pixels[p + 3] = a
        }
        return (RGBAImage(width: width, height: height, pixels: pixels), space)
    }

    /// Writes 8-bit RGBA with straight alpha, or RGB if `opaque`.
    public static func writePNG(_ image: RGBAImage, space: CGColorSpace, to url: URL, opaque: Bool = false) throws {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for p in 0..<bytes.count {
            bytes[p] = UInt8((min(1, max(0, image.pixels[p])) * 255).rounded())
        }
        let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .last
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                  width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MatteError.unwritable(url.path) }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw MatteError.unwritable(url.path) }
    }
}
