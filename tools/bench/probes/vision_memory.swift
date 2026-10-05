// Probe: phys_footprint after Vision classify + text boxes + .fast OCR, then while idle (+5 s, +30 s, +65 s).
// Finding (2026-10-04, M3): ~+60 MB while active, back to ~+20 MB within ~5 s of the last request.
// Run: swiftc -O tools/bench/probes/vision_memory.swift -o "$TMPDIR/vision_memory" && "$TMPDIR/vision_memory"

import AppKit
import Foundation
import ImageIO
import Vision
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
print(String(format: "start foot %.0fMB", physFootprintMB()))
autoreleasepool {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "/Library/User Pictures/Flowers/Dahlia.heic") as CFURL, nil)!
    let th = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 384, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
    try! VNImageRequestHandler(cgImage: th, options: [:]).perform([VNClassifyImageRequest(), VNDetectTextRectanglesRequest()])
    let ctx = CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("TOTAL 14.55\nTAX 1.08\nSUBTOTAL 13.47" as NSString).draw(in: CGRect(x: 80, y: 80, width: 1040, height: 1440), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 40, weight: .regular)])
    NSGraphicsContext.restoreGraphicsState()
    let r = VNRecognizeTextRequest(); r.recognitionLevel = .fast; r.usesLanguageCorrection = false
    try! VNImageRequestHandler(cgImage: ctx.makeImage()!, options: [:]).perform([r])
}
print(String(format: "after classify+rects+OCR fast, objects released: foot %.0fMB", physFootprintMB()))
var elapsed = 0
for wait in [5, 25, 35] { Thread.sleep(forTimeInterval: Double(wait)); elapsed += wait; print(String(format: "  +%ds idle: foot %.0fMB", elapsed, physFootprintMB())) }
