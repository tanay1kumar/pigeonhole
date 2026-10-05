// Probe: Vision classify cost cold, immediately warm, after 8 s idle, and after 8 s idle while holding a request object.
// Finding (2026-10-04, M3): Vision unloads within seconds of the last request even if a request object is kept; re-warm costs ~8-35 ms.
// Run: swiftc -O tools/bench/probes/vision_warmth.swift -o "$TMPDIR/vision_warmth" && "$TMPDIR/vision_warmth"

import Foundation
import ImageIO
import Vision
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func msd(_ t: UInt64) -> Double { Double(now() - t) / 1e6 }
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
let urls = ["Dahlia", "Poppy", "Lotus"].map { URL(fileURLWithPath: "/Library/User Pictures/Flowers/\($0).heic") }
let thumbs = urls.map { CGImageSourceCreateThumbnailAtIndex(CGImageSourceCreateWithURL($0 as CFURL, nil)!, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 384, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)! }
func classifyOnce(_ i: Int) -> Double { autoreleasepool { let t = now(); try! VNImageRequestHandler(cgImage: thumbs[i % 3], options: [:]).perform([VNClassifyImageRequest()]); return msd(t) } }
print(String(format: "first (cold) %.1f ms foot %.0fMB", classifyOnce(0), physFootprintMB()))
print(String(format: "immediately again %.1f ms foot %.0fMB", classifyOnce(1), physFootprintMB()))
Thread.sleep(forTimeInterval: 8)
print(String(format: "after 8 s with no live objects: foot %.0fMB; classify %.1f ms; foot %.0fMB", physFootprintMB(), classifyOnce(2), physFootprintMB()))
// now keep a request object alive across the idle period
let keep = VNClassifyImageRequest()
try VNImageRequestHandler(cgImage: thumbs[0], options: [:]).perform([keep])
Thread.sleep(forTimeInterval: 8)
print(String(format: "after 8 s holding a VNClassifyImageRequest: foot %.0fMB; classify(new req) %.1f ms", physFootprintMB(), classifyOnce(1)))
withExtendedLifetime(keep) {}
