// probe: how many text boxes VNDetectTextRectanglesRequest finds at different thumbnail sizes
// result: 0 boxes at 384 px even on receipts, 16 at 768-1600 px, so a text box ocr gate needs the big image
// put a retina screenshot at ./shot.png for a screenshot row, writes r600/r1200/r3024.png here
// run: mkdir -p "$TMPDIR/probes" && cd "$TMPDIR/probes" && swiftc -O "<repo>/tools/bench/probes/text_boxes.swift" -o text_boxes && ./text_boxes

import AppKit
import ImageIO
import Vision
import UniformTypeIdentifiers

func render(_ w: Int, _ h: Int, _ text: String, _ size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    (text as NSString).draw(in: CGRect(x: 40, y: 40, width: w - 80, height: h - 80), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState(); return ctx.makeImage()!
}
func save(_ img: CGImage, _ name: String) -> URL {
    let url = URL(fileURLWithPath: name)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d); return url
}
func boxes(_ url: URL, _ max: Int) -> (Int, Int) {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: max, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
    let t = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)!
    let r = VNDetectTextRectanglesRequest(); try? VNImageRequestHandler(cgImage: t, options: [:]).perform([r])
    return (r.results?.count ?? 0, t.width)
}
let receiptText = "TRADER JOE'S #552\n123 MAIN ST\n\nBANANAS        0.99\nOAT MILK       3.49\nCOFFEE BEANS   8.99\n\nSUBTOTAL      13.47\nTAX            1.08\nTOTAL        $14.55\n\nVISA ****1234\nTHANK YOU"
let inputs: [(String, URL)] = [
    ("receipt 600x800 22pt", save(render(600, 800, receiptText, 22), "r600.png")),
    ("receipt 1200x1600 40pt", save(render(1200, 1600, receiptText, 40), "r1200.png")),
    ("receipt photo-like 3024x4032 60pt", save(render(3024, 4032, receiptText, 60), "r3024.png")),

]
var all = inputs
if FileManager.default.fileExists(atPath: "shot.png") { all.append(("screenshot ./shot.png", URL(fileURLWithPath: "shot.png"))) }
for (name, url) in all {
    let res = [384, 768, 1024, 1600].map { m -> String in let (n, w) = boxes(url, m); return "\(m)px(w\(w)):\(n)" }
    print("\(name): text boxes by thumbnail max size -> \(res.joined(separator: "  "))")
}
