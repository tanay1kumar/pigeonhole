// benchmark 1 of 2, apple's on-device models for the destination classifier
// numbers are in the plan under measurements (m3, macos 15.6)
//
// measures vision classify (cold + warm) and feature prints on the 512x512 heic photos
// in /Library/User Pictures, ocr + text boxes on a rendered receipt, NLEmbedding
// word/sentence distances between folder names and sample texts, and contextual embedding load cost
//
// memory column is this process's rss, cumulative, includes shared framework pages
// so only compare relative cost, it's not activity monitor's number
// the "full decode" line is lazy (no kCGImageSourceShouldCacheImmediately) so its ~7ms
// isn't a real decode, bench_extraction.swift measures the real one
// sample texts are handwritten for this so accuracy is only a rough hint
//
// run from the repo root:
//   swiftc -O tools/bench/bench_models.swift -o "$TMPDIR/bench_models" && "$TMPDIR/bench_models"

import AppKit
import Foundation
import ImageIO
import NaturalLanguage
import Vision

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ t: UInt64) -> String { String(format: "%.1fms", Double(now() - t) / 1e6) }

func residentMB() -> String {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? String(format: "%.0fMB", Double(info.resident_size) / 1_048_576) : "?"
}

func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

func textImage(_ text: String) -> CGImage {
    let size = CGSize(width: 600, height: 800)
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                                                .foregroundColor: NSColor.black]
    (text as NSString).draw(in: CGRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

print("== start", residentMB())

// 1. vision taxonomy
let taxonomy = try VNClassifyImageRequest().supportedIdentifiers()
print("vision taxonomy:", taxonomy.count, "labels")
let interesting = taxonomy.filter { id in
    ["document", "paper", "text", "screen", "receipt", "print", "flower", "menu", "whiteboard", "diagram", "chart", "poster", "illustration", "handwrit", "map", "sign"].contains { id.contains($0) }
}
print("relevant labels:", interesting.joined(separator: ", "))

// 2. classify + feature print on real flower photos
let flowerDir = URL(fileURLWithPath: "/Library/User Pictures/Flowers")
let animalDir = URL(fileURLWithPath: "/Library/User Pictures/Animals")
let flowers = try FileManager.default.contentsOfDirectory(at: flowerDir, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
let animals = try FileManager.default.contentsOfDirectory(at: animalDir, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }

func classify(_ image: CGImage) throws -> [(String, Float)] {
    let req = VNClassifyImageRequest()
    try VNImageRequestHandler(cgImage: image).perform([req])
    return (req.results ?? []).filter { $0.confidence > 0.1 }.prefix(5).map { ($0.identifier, $0.confidence) }
}

func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
    let req = VNGenerateImageFeaturePrintRequest()
    try VNImageRequestHandler(cgImage: image).perform([req])
    return req.results!.first!
}

var t = now()
let fullDecode = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(flowers[0] as CFURL, nil)!, 0, nil)!
print("full decode \(flowers[0].lastPathComponent) \(fullDecode.width)x\(fullDecode.height):", ms(t))
t = now()
let small = thumbnail(flowers[0], maxPixel: 384)!
print("thumbnail 384px:", ms(t))

t = now()
_ = try classify(small)
print("classify COLD:", ms(t), residentMB())

var prints: [(String, VNFeaturePrintObservation)] = []
for url in flowers.prefix(5) + animals.prefix(2) {
    let img = thumbnail(url, maxPixel: 384)!
    t = now()
    let labels = try classify(img)
    let tc = ms(t)
    t = now()
    let fp = try featurePrint(img)
    let tf = ms(t)
    prints.append((url.lastPathComponent, fp))
    print("  \(url.lastPathComponent): classify \(tc), featureprint \(tf) ->",
          labels.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
}
print("after vision", residentMB(), "featureprint dims:", prints[0].1.elementCount)
func dist(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
    var d: Float = 0; try! a.computeDistance(&d, to: b); return d
}
print("featureprint distance flower-flower:", String(format: "%.3f", dist(prints[0].1, prints[1].1)),
      " flower-flower:", String(format: "%.3f", dist(prints[2].1, prints[3].1)),
      " flower-animal:", String(format: "%.3f", dist(prints[0].1, prints[5].1)),
      " flower-animal:", String(format: "%.3f", dist(prints[2].1, prints[6].1)))

// 3. ocr on a receipt-like image
let receiptText = "TRADER JOE'S #552\n123 MAIN ST\n\nBANANAS        0.99\nOAT MILK       3.49\nCOFFEE BEANS   8.99\n\nSUBTOTAL      13.47\nTAX            1.08\nTOTAL        $14.55\n\nVISA ****1234\nTHANK YOU FOR SHOPPING"
let receipt = textImage(receiptText)
print("receipt image labels:", try classify(receipt).map { "\($0.0) \(String(format: "%.2f", $0.1))" })
for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    t = now()
    try VNImageRequestHandler(cgImage: receipt).perform([req])
    let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    print("OCR \(level == .fast ? "fast" : "accurate"):", ms(t), "->", text.prefix(60))
}
let flowerOCR = VNRecognizeTextRequest(); flowerOCR.recognitionLevel = .fast
t = now(); try VNImageRequestHandler(cgImage: small).perform([flowerOCR])
print("OCR fast on flower photo:", ms(t), "lines:", flowerOCR.results?.count ?? 0)
let rects = VNDetectTextRectanglesRequest()
t = now(); try VNImageRequestHandler(cgImage: small).perform([rects])
print("text-rect detect on flower:", ms(t), "boxes:", rects.results?.count ?? 0)
t = now(); try VNImageRequestHandler(cgImage: receipt).perform([rects])
print("text-rect detect on receipt:", ms(t), "boxes:", rects.results?.count ?? 0)
print("after OCR", residentMB())

// 4. NLEmbedding word + sentence
t = now()
let words = NLEmbedding.wordEmbedding(for: .english)!
print("\nword embedding load:", ms(t), "dims:", words.dimension, residentMB())
for (folder, probes) in [("flowers", ["daisy", "rose", "petal", "plant", "invoice", "resume"]),
                         ("resumes", ["experience", "education", "skills", "employment", "invoice", "flower"]),
                         ("receipts", ["total", "tax", "invoice", "purchase", "education", "flower"]),
                         ("resume", ["experience", "education", "skills", "cv", "invoice"])] {
    print("  word dist \(folder):", probes.map { "\($0) \(String(format: "%.2f", words.distance(between: folder, and: $0)))" }.joined(separator: ", "))
}

t = now()
let sentences = NLEmbedding.sentenceEmbedding(for: .english)!
print("sentence embedding load:", ms(t), "dims:", sentences.dimension, residentMB())
let resumeText = "Jordan Lee. Software Engineer. Experience: Acme Corp 2019-2023, built distributed systems in Go. Education: BS Computer Science, State University. Skills: Swift, Python, Kubernetes."
let docs = ["resume text": resumeText, "receipt text": receiptText.replacingOccurrences(of: "\n", with: " "),
            "flower labels": "flower daisy plant petal", "lecture notes": "Lecture 5: binary search trees, insertion, deletion, AVL rotations. Homework due Friday."]
let folderNames = ["Resumes", "Receipts", "Flowers", "School"]
let expanded = ["Resumes": "resume CV curriculum vitae work experience education skills employment job application",
                "Receipts": "receipt invoice purchase order total tax subtotal payment paid amount store",
                "Flowers": "flowers flower plant blossom garden petal bloom",
                "School": "school class lecture homework assignment notes course exam syllabus"]
t = now()
_ = sentences.vector(for: resumeText)
print("sentence vector (resume, ~40 words):", ms(t))
for (name, text) in docs.sorted(by: { $0.key < $1.key }) {
    let plain = folderNames.map { "\($0) \(String(format: "%.2f", sentences.distance(between: text, and: $0)))" }
    let rich = folderNames.map { "\($0) \(String(format: "%.2f", sentences.distance(between: text, and: expanded[$0]!)))" }
    print("  \(name)\n    vs bare name:     ", plain.joined(separator: "  "), "\n    vs expanded name: ", rich.joined(separator: "  "))
}

// 5. contextual embedding (macos 14+)
if let ctxEmb = NLContextualEmbedding(language: .english) {
    print("\ncontextual embedding: assets available =", ctxEmb.hasAvailableAssets, "dims:", ctxEmb.dimension)
    if ctxEmb.hasAvailableAssets {
        t = now(); try ctxEmb.load(); print("contextual load:", ms(t), residentMB())
        t = now(); _ = try ctxEmb.embeddingResult(for: resumeText, language: .english); print("contextual embed resume:", ms(t), residentMB())
        t = now(); _ = try ctxEmb.embeddingResult(for: receiptText, language: .english); print("contextual embed receipt (warm):", ms(t))
    }
}
print("== end", residentMB())
