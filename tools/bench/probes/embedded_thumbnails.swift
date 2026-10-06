// probe: what CGImageSourceCreateThumbnailAtIndex returns for 12mp jpeg/heic files with an embedded thumbnail
// result: ...FromImageIfAbsent returns the embedded thumbnail (jpeg 160x120, heic 320x240) at any max size
// ...FromImageAlways at 1600 gives 1600x1200 (jpeg ~37 ms, heic ~52 ms), writes emb.jpg / emb.heic here
// run: mkdir -p "$TMPDIR/probes" && cd "$TMPDIR/probes" && swiftc -O "<repo>/tools/bench/probes/embedded_thumbnails.swift" -o embedded_thumbnails && ./embedded_thumbnails

import AppKit
import ImageIO
import UniformTypeIdentifiers
// a 4032x3024 "photo" (receipt-like text) saved as jpeg and heic with an embedded thumbnail
let w = 4032, h = 3024
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
("TOTAL $14.55\nTAX 1.08\nVISA ****1234" as NSString).draw(in: CGRect(x: 200, y: 200, width: 3600, height: 2600), withAttributes: [.font: NSFont.systemFont(ofSize: 160), .foregroundColor: NSColor.black])
NSGraphicsContext.restoreGraphicsState()
let img = ctx.makeImage()!
for (ext, type) in [("jpg", UTType.jpeg), ("heic", UTType.heic)] {
    let url = URL(fileURLWithPath: "emb.\(ext)")
    let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, [kCGImageDestinationEmbedThumbnail: true, kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(d)
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    for (label, key) in [("IfAbsent", kCGImageSourceCreateThumbnailFromImageIfAbsent), ("Always", kCGImageSourceCreateThumbnailFromImageAlways)] {
        for maxPx in [384, 1600] {
            let o: [CFString: Any] = [key: true, kCGImageSourceThumbnailMaxPixelSize: maxPx, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            let t0 = DispatchTime.now().uptimeNanoseconds
            let th = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)!
            print(String(format: "%@ %@ max %d -> %dx%d in %.1f ms", ext, label, maxPx, th.width, th.height, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
        }
    }
}
