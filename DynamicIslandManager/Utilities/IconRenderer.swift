#if DEBUG
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// the app icon, drawn here so it can be made again at any size, --render-icon writes the set
// apple's macos grid, an 824 pt body on a 1024 canvas with a soft shadow under it
enum IconRenderer {
    static let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                                     (256, 1), (256, 2), (512, 1), (512, 2)]

    static func render(pixels: Int) -> CGImage? {
        let s = CGFloat(pixels) / 1024
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: s, y: s)
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = continuousRect(body, radius: 185)

        // the shadow every macos icon sits on
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(squircle)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()

        // the body, near black, a touch lighter at the top like it's lit from above
        context.saveGState()
        context.addPath(squircle)
        context.clip()
        let bodyColors = [CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1), CGColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1)] as CFArray
        context.drawLinearGradient(CGGradient(colorsSpace: nil, colors: bodyColors, locations: [0, 1])!,
                                   start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

        // a soft light behind the island, so the black pill reads on a black body
        let pill = CGRect(x: 512 - 225, y: 924 - 100 - 100, width: 450, height: 100)
        let glowColors = [CGColor(srgbRed: 0.55, green: 0.72, blue: 1, alpha: 0.42), CGColor(srgbRed: 0.55, green: 0.72, blue: 1, alpha: 0)] as CFArray
        let glow = CGGradient(colorsSpace: nil, colors: glowColors, locations: [0, 1])!
        context.saveGState()
        context.translateBy(x: pill.midX, y: pill.midY)
        context.scaleBy(x: 1.9, y: 0.75)
        context.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 260, options: [])
        context.restoreGState()

        // a faint highlight along the top edge of the body
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        context.setLineWidth(4)
        context.addPath(continuousRect(body.insetBy(dx: 2, dy: 2), radius: 183))
        context.strokePath()
        context.restoreGState()

        // the island itself, true black with a thin lit rim
        let capsule = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
        context.addPath(capsule)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.saveGState()
        context.addPath(capsule)
        context.setLineWidth(3)
        context.setStrokeColor(CGColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 0.35))
        context.strokePath()
        context.restoreGState()

        // an arrow going up into it, files go up to drive
        let arrow = CGMutablePath()
        let x: CGFloat = 512, top: CGFloat = 610, bottom: CGFloat = 380
        arrow.move(to: CGPoint(x: x, y: bottom))
        arrow.addLine(to: CGPoint(x: x, y: top))
        arrow.move(to: CGPoint(x: x - 92, y: top - 92))
        arrow.addLine(to: CGPoint(x: x, y: top))
        arrow.addLine(to: CGPoint(x: x + 92, y: top - 92))
        context.saveGState()
        context.addPath(arrow)
        context.setLineWidth(58)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        let arrowColors = [CGColor(srgbRed: 0.98, green: 0.99, blue: 1, alpha: 1), CGColor(srgbRed: 0.72, green: 0.80, blue: 0.95, alpha: 1)] as CFArray
        context.drawLinearGradient(CGGradient(colorsSpace: nil, colors: arrowColors, locations: [0, 1])!,
                                   start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: bottom - 40), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
        return context.makeImage()
    }

    // apple's continuous corner, a copy of IslandShape's curve, change both together
    static func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
        let path = CGMutablePath()
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        path.move(to: p(minX + 1.52866483 * r, minY))
        path.addLine(to: p(maxX - 1.52866483 * r, minY))
        path.addCurve(to: p(maxX - 0.63149399 * r, minY + 0.07491100 * r), control1: p(maxX - 1.08849296 * r, minY), control2: p(maxX - 0.86840694 * r, minY))
        path.addCurve(to: p(maxX - 0.07491100 * r, minY + 0.63149399 * r), control1: p(maxX - 0.37282392 * r, minY + 0.16905899 * r), control2: p(maxX - 0.16905899 * r, minY + 0.37282392 * r))
        path.addCurve(to: p(maxX, minY + 1.52866483 * r), control1: p(maxX, minY + 0.86840694 * r), control2: p(maxX, minY + 1.08849296 * r))
        path.addLine(to: p(maxX, maxY - 1.52866483 * r))
        path.addCurve(to: p(maxX - 0.07491100 * r, maxY - 0.63149399 * r), control1: p(maxX, maxY - 1.08849296 * r), control2: p(maxX, maxY - 0.86840694 * r))
        path.addCurve(to: p(maxX - 0.63149399 * r, maxY - 0.07491100 * r), control1: p(maxX - 0.16905899 * r, maxY - 0.37282392 * r), control2: p(maxX - 0.37282392 * r, maxY - 0.16905899 * r))
        path.addCurve(to: p(maxX - 1.52866483 * r, maxY), control1: p(maxX - 0.86840694 * r, maxY), control2: p(maxX - 1.08849296 * r, maxY))
        path.addLine(to: p(minX + 1.52866483 * r, maxY))
        path.addCurve(to: p(minX + 0.63149399 * r, maxY - 0.07491100 * r), control1: p(minX + 1.08849296 * r, maxY), control2: p(minX + 0.86840694 * r, maxY))
        path.addCurve(to: p(minX + 0.07491100 * r, maxY - 0.63149399 * r), control1: p(minX + 0.37282392 * r, maxY - 0.16905899 * r), control2: p(minX + 0.16905899 * r, maxY - 0.37282392 * r))
        path.addCurve(to: p(minX, maxY - 1.52866483 * r), control1: p(minX, maxY - 0.86840694 * r), control2: p(minX, maxY - 1.08849296 * r))
        path.addLine(to: p(minX, minY + 1.52866483 * r))
        path.addCurve(to: p(minX + 0.07491100 * r, minY + 0.63149399 * r), control1: p(minX, minY + 1.08849296 * r), control2: p(minX, minY + 0.86840694 * r))
        path.addCurve(to: p(minX + 0.63149399 * r, minY + 0.07491100 * r), control1: p(minX + 0.16905899 * r, minY + 0.37282392 * r), control2: p(minX + 0.37282392 * r, minY + 0.16905899 * r))
        path.addCurve(to: p(minX + 1.52866483 * r, minY), control1: p(minX + 0.86840694 * r, minY), control2: p(minX + 1.08849296 * r, minY))
        path.closeSubpath()
        return path
    }

    // every size the icon set lists, and its contents file
    static func writeIconSet(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var images: [[String: String]] = []
        for (points, scale) in sizes {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            guard let image = render(pixels: points * scale),
                  let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("Contents.json"))
    }
}
#endif
