// benchmark 2 of 2, extraction costs at realistic sizes
// measured on an m3 with macos 15.6
//
// measures 12mp heic/jpeg full decode vs 384px thumbnail (+ classify), warm ocr fast vs accurate,
// pdfkit text from the first 2 pages, docx via NSAttributedString, where-froms on the
// first 30 items in ~/Downloads (counts only), and contextual embedding similarity + unload()
//
// arg 1 is a scratch dir for generated files (big.heic, big.jpg, resume.pdf/.txt/.docx)
// the 12mp image is Sunflower.heic upscaled so it has no embedded thumbnail
// starts at ~175MB rss because that bitmap gets made first
// memory is resident_size (rss), cumulative, so only compare relative cost
//
// run from the repo root:
//   mkdir -p "$TMPDIR/bench-files"
//   swiftc -O tools/bench/bench_extraction.swift -o "$TMPDIR/bench_extraction" && "$TMPDIR/bench_extraction" "$TMPDIR/bench-files"

import AppKit
import Foundation
import ImageIO
import NaturalLanguage
import PDFKit
import UniformTypeIdentifiers
import Vision

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ t: UInt64) -> String { String(format: "%.1fms", Double(now() - t) / 1e6) }
func residentMB() -> String {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return String(format: "%.0fMB", Double(info.resident_size) / 1_048_576)
}
func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])

// make a 12mp photo (4032x3024) as heic and jpeg from a flower
let flower = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: "/Library/User Pictures/Flowers/Sunflower.heic") as CFURL, nil)!, 0, nil)!
let big = CGContext(data: nil, width: 4032, height: 3024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
big.interpolationQuality = .high
big.draw(flower, in: CGRect(x: 0, y: 0, width: 4032, height: 3024))
let bigImage = big.makeImage()!
for (ext, type) in [("heic", UTType.heic), ("jpg", UTType.jpeg)] {
    let url = dir.appendingPathComponent("big.\(ext)")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, bigImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
print("== start", residentMB())
for ext in ["heic", "jpg"] {
    let url = dir.appendingPathComponent("big.\(ext)")
    for round in 1...2 {
        var t = now()
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
        let fullTime = ms(t)
        t = now()
        let req = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: full).perform([req])
        let fullClassify = ms(t)
        t = now()
        let thumb = thumbnail(url, maxPixel: 384)!
        let thumbTime = ms(t)
        t = now()
        try VNImageRequestHandler(cgImage: thumb).perform([VNClassifyImageRequest()])
        print("12MP \(ext) round \(round): full decode \(fullTime) + classify \(fullClassify) | 384px thumbnail \(thumbTime) + classify \(ms(t))  mem \(residentMB())")
    }
}

// warm ocr timings
func textImage(_ text: String) -> CGImage {
    let ctx = CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    (text as NSString).draw(in: CGRect(x: 80, y: 80, width: 1040, height: 1440), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 40, weight: .regular), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState(); return ctx.makeImage()!
}
let receipt = textImage("TRADER JOE'S #552\n123 MAIN ST\n\nBANANAS        0.99\nOAT MILK       3.49\nCOFFEE BEANS   8.99\n\nSUBTOTAL      13.47\nTAX            1.08\nTOTAL        $14.55\n\nVISA ****1234\nTHANK YOU")
for (label, level, correction) in [("fast", VNRequestTextRecognitionLevel.fast, false), ("fast", .fast, false), ("fast", .fast, false), ("accurate", .accurate, true), ("accurate", .accurate, true)] {
    let req = VNRecognizeTextRequest(); req.recognitionLevel = level; req.usesLanguageCorrection = correction
    let t = now(); try VNImageRequestHandler(cgImage: receipt).perform([req])
    print("OCR \(label) warm-ish: \(ms(t)) lines \(req.results?.count ?? 0)  mem \(residentMB())")
}

// text pdf via CoreText, then PDFKit extraction
let pdfURL = dir.appendingPathComponent("resume.pdf")
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
let resume = String(repeating: "Jordan Lee. Software Engineer. Experience: Acme Corp 2019-2023, built distributed systems. Education: BS Computer Science. Skills: Swift, Python, Kubernetes. ", count: 12)
for _ in 0..<3 {
    pdf.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
    (resume as NSString).draw(in: box.insetBy(dx: 50, dy: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
    NSGraphicsContext.restoreGraphicsState(); pdf.endPDFPage()
}
pdf.closePDF()
for round in 1...2 {
    let t = now()
    let doc = PDFDocument(url: pdfURL)!
    var text = ""
    for i in 0..<min(2, doc.pageCount) { text += doc.page(at: i)?.string ?? "" }
    print("PDF open + 2 pages text round \(round): \(ms(t)) chars \(text.count)")
}

// docx via NSAttributedString
let txtURL = dir.appendingPathComponent("resume.txt"); try resume.write(to: txtURL, atomically: true, encoding: .utf8)
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/textutil"); task.arguments = ["-convert", "docx", txtURL.path, "-output", dir.appendingPathComponent("resume.docx").path]; try task.run(); task.waitUntilExit()
for round in 1...2 {
    let t = now()
    let attr = try NSAttributedString(url: dir.appendingPathComponent("resume.docx"), options: [:], documentAttributes: nil)
    print("DOCX read round \(round): \(ms(t)) chars \(attr.length)")
}

// spotlight metadata, where-froms on a downloaded file + content type
let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
let t0 = now()
var withSource = 0, checked = 0
if let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) {
    for url in items.prefix(30) {
        checked += 1
        if let item = MDItemCreateWithURL(nil, url as CFURL), MDItemCopyAttribute(item, kMDItemWhereFroms) != nil { withSource += 1 }
    }
}
print("whereFroms lookup: \(checked) Downloads files, \(withSource) have a source URL, total \(ms(t0))")

// contextual embedding, does mean pooled bert separate better and does unload free memory
func meanVector(_ emb: NLContextualEmbedding, _ text: String) throws -> [Double] {
    let r = try emb.embeddingResult(for: text, language: .english)
    var sum = [Double](repeating: 0, count: emb.dimension); var n = 0.0
    r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in for i in 0..<v.count { sum[i] += v[i] }; n += 1; return true }
    return sum.map { $0 / max(n, 1) }
}
func cosine(_ a: [Double], _ b: [Double]) -> Double { var d = 0.0, x = 0.0, y = 0.0; for i in 0..<a.count { d += a[i]*b[i]; x += a[i]*a[i]; y += b[i]*b[i] }; return d / (x.squareRoot() * y.squareRoot()) }
let docs = ["resume": "Jordan Lee. Software Engineer. Experience: Acme Corp 2019-2023, built distributed systems in Go. Education: BS Computer Science, State University. Skills: Swift, Python, Kubernetes.",
            "receipt": "TRADER JOE'S 552 123 MAIN ST BANANAS 0.99 OAT MILK 3.49 SUBTOTAL 13.47 TAX 1.08 TOTAL 14.55 VISA 1234 THANK YOU",
            "lecture": "Lecture 5: binary search trees, insertion, deletion, AVL rotations. Homework due Friday.",
            "flower": "flower daisy plant petal"]
let folders = ["Resumes": "resume CV curriculum vitae work experience education skills employment job application",
               "Receipts": "receipt invoice purchase order total tax subtotal payment paid amount store",
               "Flowers": "flowers flower plant blossom garden petal bloom",
               "School": "school class lecture homework assignment notes course exam syllabus"]
let emb = NLContextualEmbedding(language: .english)!
try emb.load()
let folderVecs = try folders.mapValues { try meanVector(emb, $0) }
for (name, text) in docs.sorted(by: { $0.key < $1.key }) {
    let v = try meanVector(emb, text)
    let scores = folderVecs.map { ($0.key, cosine(v, $0.value)) }.sorted { $0.1 > $1.1 }
    print("contextual \(name):", scores.map { "\($0.0) \(String(format: "%.3f", $0.1))" }.joined(separator: "  "))
}
print("contextual loaded mem", residentMB())
emb.unload()
Thread.sleep(forTimeInterval: 1)
print("after unload mem", residentMB())
