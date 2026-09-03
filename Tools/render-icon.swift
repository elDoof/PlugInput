// Renders PlugInput's app icon at every size macOS asks for, as a CoreGraphics drawing.
//
// Drawn in code rather than shipped as a binary asset so the icon is reviewable in a diff and
// reproducible from a checkout: `./make-icon.sh` turns this into Resources/AppIcon.icns.
//
// Each size is rendered natively rather than downscaled from 1024. A 16pt icon is 13 points of
// artwork after the standard margin, and letting CoreGraphics rasterise the geometry at the
// target size keeps the bars on whole-ish pixels instead of smearing them.
//
// Usage: swift Tools/render-icon.swift <output-directory>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

/// Simple linear RGB pair, so the drawing code reads in colours rather than in component arrays.
struct Colour {
    let red, green, blue, alpha: CGFloat

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Hex as written in a design tool, so the constants below can be compared to one by eye.
    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha
        )
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    func mixed(with other: Colour, by amount: CGFloat) -> Colour {
        Colour(
            red + (other.red - red) * amount,
            green + (other.green - green) * amount,
            blue + (other.blue - blue) * amount,
            alpha + (other.alpha - alpha) * amount
        )
    }
}

enum Palette {
    /// A dark plate rather than a bright one: this is a utility that sits in the menu bar next
    /// to system icons, and the bars need somewhere dark to glow against at 16pt.
    static let plateTop = Colour(hex: 0x2A2D4A)
    static let plateBottom = Colour(hex: 0x0D0F1E)

    /// The bars run cyan to indigo left to right — input entering the chain and leaving it
    /// changed, which is the one idea the whole app is about.
    static let signalStart = Colour(hex: 0x22D3EE)
    static let signalEnd = Colour(hex: 0x818CF8)

    static let rimLight = Colour(1, 1, 1, 0.12)
    static let topSheen = Colour(1, 1, 1, 0.10)
}

// MARK: - Geometry

/// Every dimension as a fraction of the canvas, so one set of numbers drives all ten sizes.
enum Metrics {
    /// Apple's icon grid: the plate is 824pt of a 1024pt canvas, leaving the margin that the
    /// Dock and Finder expect to be able to eat into.
    static let plateInset: CGFloat = 100.0 / 1024.0
    static let cornerRadius: CGFloat = 185.0 / 1024.0

    static let barWidth: CGFloat = 104.0 / 1024.0
    static let barGap: CGFloat = 56.0 / 1024.0
    /// The tallest bar, as a fraction of the canvas.
    static let barMaximumHeight: CGFloat = 520.0 / 1024.0

    /// Five bars, not the seven this started as. Five stays legible at 16pt — where a bar is
    /// under two pixels wide — while still reading as a level meter rather than as a logo.
    static let barHeights: [CGFloat] = [0.40, 0.70, 1.0, 0.70, 0.40]
}

// MARK: - Drawing

func drawIcon(size: CGFloat, into context: CGContext) {
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let inset = size * Metrics.plateInset
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * Metrics.cornerRadius
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    fillVerticalGradient(
        in: plate, from: Palette.plateBottom, to: Palette.plateTop, context: context
    )
    drawTopSheen(over: plate, context: context)
    drawBars(in: plate, size: size, context: context)
    context.restoreGState()

    // A hairline rim keeps the plate's edge from disappearing into a dark desktop background.
    context.addPath(platePath)
    context.setStrokeColor(Palette.rimLight.cgColor)
    context.setLineWidth(max(1, size / 256))
    context.strokePath()
}

private func fillVerticalGradient(
    in rect: CGRect, from bottom: Colour, to top: Colour, context: CGContext
) {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [bottom.cgColor, top.cgColor] as CFArray,
        locations: [0, 1]
    ) else { return }

    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
}

/// A soft light across the top third, which is what stops a flat gradient looking printed on.
private func drawTopSheen(over plate: CGRect, context: CGContext) {
    let sheen = CGRect(
        x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2
    )
    fillVerticalGradient(
        in: sheen, from: Colour(1, 1, 1, 0), to: Palette.topSheen, context: context
    )
}

private func drawBars(in plate: CGRect, size: CGFloat, context: CGContext) {
    let width = size * Metrics.barWidth
    let gap = size * Metrics.barGap
    let maximumHeight = size * Metrics.barMaximumHeight
    let count = Metrics.barHeights.count
    let totalWidth = width * CGFloat(count) + gap * CGFloat(count - 1)
    var x = plate.midX - totalWidth / 2

    // One shadow for the whole group, set before the loop: bars overlap nothing, so there is
    // nothing for a per-bar shadow to fall on that a group shadow does not already cover.
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.006),
        blur: size * 0.022,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
    )

    for (index, fraction) in Metrics.barHeights.enumerated() {
        let height = maximumHeight * fraction
        let bar = CGRect(x: x, y: plate.midY - height / 2, width: width, height: height)
        let position = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
        let colour = Palette.signalStart.mixed(with: Palette.signalEnd, by: position)

        context.setFillColor(colour.cgColor)
        context.addPath(CGPath(
            roundedRect: bar, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil
        ))
        context.fillPath()

        x += width + gap
    }
}

// MARK: - Output

func renderPNG(size: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.contextUnavailable(size: size)
    }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    drawIcon(size: CGFloat(size), into: context)

    guard let image = context.makeImage() else { throw IconError.imageUnavailable(size: size) }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw IconError.destinationUnavailable(url: url)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.writeFailed(url: url)
    }
}

enum IconError: Error, CustomStringConvertible {
    case missingArgument
    case contextUnavailable(size: Int)
    case imageUnavailable(size: Int)
    case destinationUnavailable(url: URL)
    case writeFailed(url: URL)

    var description: String {
        switch self {
        case .missingArgument:
            return "usage: swift Tools/render-icon.swift <output-directory>"
        case .contextUnavailable(let size):
            return "could not create a \(size)x\(size) bitmap context"
        case .imageUnavailable(let size):
            return "could not rasterise the \(size)x\(size) icon"
        case .destinationUnavailable(let url):
            return "could not open \(url.path) for writing"
        case .writeFailed(let url):
            return "could not write \(url.path)"
        }
    }
}

/// The exact set `iconutil` expects in a `.iconset`. A missing entry is not an error there —
/// it silently produces an icns without that representation, which then falls back to a blurry
/// scale of a neighbour at precisely the size a user looks at most.
let representations: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

do {
    guard CommandLine.arguments.count > 1 else { throw IconError.missingArgument }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )

    for representation in representations {
        let url = directory.appendingPathComponent(representation.name)
        try renderPNG(size: representation.pixels, to: url)
        print("    \(representation.name) (\(representation.pixels)px)")
    }
} catch {
    FileHandle.standardError.write(Data("!!! \(error)\n".utf8))
    exit(1)
}
