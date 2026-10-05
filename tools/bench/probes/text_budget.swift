// Probe: sentence-embedding cost by word count, and the full warm text-PDF path (PDFKit + tokenize + MDItem + embedding).
// Finding (2026-10-04, M3): 30 words ~9.5 ms, 60 words ~15.8 ms; text PDF path 17-20 ms warm with a 62-word summary.
// Writes resume_probe.pdf into the current directory.
// Run: mkdir -p "$TMPDIR/probes" && cd "$TMPDIR/probes" && swiftc -O "<repo>/tools/bench/probes/text_budget.swift" -o text_budget && ./text_budget

import Foundation
import NaturalLanguage
import PDFKit
import AppKit
import CoreServices

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func median(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count/2] }
let base = "jordan lee software engineer experience acme corp built distributed systems education computer science skills swift python kubernetes internship gpa bachelor master linkedin proficient responsibilities references objective summary employment history "
let words = base.split(separator: " ").map(String.init)
let emb = NLEmbedding.sentenceEmbedding(for: .english)!
_ = emb.vector(for: "warm up the model please")
for n in [5, 15, 30, 45, 60, 75] {
    var ts: [Double] = []
    let s = (0..<n).map { words[$0 % words.count] }.joined(separator: " ")
    for _ in 0..<15 { let t = now(); _ = emb.vector(for: s); ts.append(Double(now() - t) / 1e6) }
    print("sentence embedding \(n) words: median \(String(format: "%.1f", median(ts))) ms, min \(String(format: "%.1f", ts.min()!))")
}
// PDF text + tokenize ~4000 chars
let pdfURL = URL(fileURLWithPath: "resume_probe.pdf")
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
let ctx = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
let text = String(repeating: "Jordan Lee. Software Engineer. Experience: Acme Corp 2019-2023, built distributed systems. Education: BS Computer Science. Skills: Swift, Python, Kubernetes. ", count: 12)
for _ in 0..<3 { ctx.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false); (text as NSString).draw(in: box.insetBy(dx: 50, dy: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 11)]); NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage() }
ctx.closePDF()
for round in 1...4 {
    var t = now()
    let doc = PDFDocument(url: pdfURL)!
    var s = ""; for i in 0..<min(2, doc.pageCount) { s += doc.page(at: i)?.string ?? "" }
    s = String(s.prefix(4000))
    let tPdf = Double(now() - t) / 1e6
    t = now()
    let tok = NLTokenizer(unit: .word); tok.string = s
    var toks: [String] = []
    tok.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in toks.append(s[r].lowercased()); return toks.count < 600 }
    let tTok = Double(now() - t) / 1e6
    t = now()
    let item = MDItemCreateWithURL(kCFAllocatorDefault, pdfURL as CFURL)
    _ = item.flatMap { MDItemCopyAttribute($0, kMDItemWhereFroms) }
    let tMd = Double(now() - t) / 1e6
    t = now()
    _ = emb.vector(for: (["resume", "probe"] + toks.prefix(60)).joined(separator: " "))
    let tEmb = Double(now() - t) / 1e6
    print(String(format: "text PDF round %d: pdfkit %.1f + tokenize(%d) %.1f + mditem %.1f + embed(62 words) %.1f = %.1f ms", round, tPdf, toks.count, tTok, tMd, tEmb, tPdf + tTok + tMd + tEmb))
}
