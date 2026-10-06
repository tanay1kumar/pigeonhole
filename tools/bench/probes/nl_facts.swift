// probe: NLEmbedding facts the classifier relies on, vocab, label mapping for folder names, distance, and
// sentence embedding cost vs text length
// note NLEmbedding.distance(.cosine) is euclidean distance of normalized vectors = sqrt(2*(1-cos)), 0-2
// run: swiftc -O tools/bench/probes/nl_facts.swift -o "$TMPDIR/nl_facts" && "$TMPDIR/nl_facts"

import Foundation
import NaturalLanguage
import Vision

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func msd(_ t: UInt64) -> Double { Double(now() - t) / 1e6 }

let words = NLEmbedding.wordEmbedding(for: .english)!
print("word vocabularySize:", words.vocabularySize, "dimension:", words.dimension, "revision:", words.revision)
for w in ["cv", "cvs", "resume", "resumes", "résumé", "receipts", "flowers", "sunflower", "tulip", "daisy", "dahlia", "lotus", "arrangement", "flower_arrangement", "lily", "orchid", "dandelion", "poppy", "rose", "petal"] {
    print("  contains(\(w)):", words.contains(w))
}

// label mapping, compare "flowers" to every vision label
let taxonomy = try VNClassifyImageRequest().supportedIdentifiers()
for tl in ["daisy", "rose", "tulip", "sunflower", "lily", "orchid", "dahlia", "dandelion", "lotus", "poppy", "flower_arrangement", "bouquet", "blossom", "petal", "receipt", "document", "printed_page", "screenshot"] {
    print("  taxonomy has \(tl):", taxonomy.contains(tl))
}
func labelWord(_ label: String) -> String? {
    let whole = label.replacingOccurrences(of: "_", with: " ")
    if words.contains(label) { return label }
    if words.contains(whole) { return whole }
    let last = label.split(separator: "_").last.map(String.init) ?? label
    return words.contains(last) ? last : nil
}
for name in ["flowers", "receipts", "resumes", "school", "screenshots"] {
    var kept: [(String, Double)] = []
    var all: [(String, Double)] = []
    for label in taxonomy {
        guard let lw = labelWord(label) else { continue }
        let d = words.distance(between: name, and: lw)
        all.append((label, d))
        let exactOrPlural = (lw == name) || (lw + "s" == name) || (name + "s" == lw)
        if d <= 0.9 || exactOrPlural { kept.append((label, d)) }
    }
    kept.sort { $0.1 < $1.1 }
    all.sort { $0.1 < $1.1 }
    print("map \(name): kept(<=0.9 or exact/plural)=\(kept.count) top15:", kept.prefix(15).map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
    if name == "flowers" {
        for l in ["daisy", "rose", "tulip", "sunflower", "lily", "dahlia", "flower_arrangement", "flower", "dandelion"] {
            if let e = all.first(where: { $0.0 == l }) { print("    flowers->\(l): \(String(format: "%.3f", e.1)) via '\(labelWord(l) ?? "nil")'") } else { print("    flowers->\(l): no vocab word") }
        }
    }
}

// count words in the "~40 word" text
let resumeText = "Jordan Lee. Software Engineer. Experience: Acme Corp 2019-2023, built distributed systems in Go. Education: BS Computer Science, State University. Skills: Swift, Python, Kubernetes."
let tok = NLTokenizer(unit: .word); tok.string = resumeText
let nTok = tok.tokens(for: resumeText.startIndex..<resumeText.endIndex).count
print("resumeText: whitespace words =", resumeText.split(separator: " ").count, " NLTokenizer words =", nTok)

// sentence embedding timing vs length (cold first, then warm)
var t = now()
let sent = NLEmbedding.sentenceEmbedding(for: .english)!
print(String(format: "sentence load %.1f ms", msd(t)))
let filler = "the quarterly report covers revenue growth customer retention hiring plans product launches marketing spend regional sales results and next year budget priorities for the engineering design and operations teams across all offices worldwide including remote staff contractors partners vendors suppliers and advisors who support the company mission every single day of the year with care and focus".split(separator: " ").map(String.init)
func text(_ n: Int) -> String { (0..<n).map { filler[$0 % filler.count] }.joined(separator: " ") }
t = now(); _ = sent.vector(for: resumeText); print(String(format: "first vector (resumeText, %d words): %.1f ms", resumeText.split(separator: " ").count, msd(t)))
for n in [23, 40, 60, 80, 120, 200] {
    var times: [Double] = []
    for r in 0..<5 { let s = text(n) + " r\(r)"; let t1 = now(); _ = sent.vector(for: s); times.append(msd(t1)) }
    times.sort()
    print(String(format: "  sentence vector %3d words: min %.1f  median %.1f  max %.1f ms", n, times[0], times[2], times[4]))
}
t = now(); _ = sent.vector(for: resumeText); print(String(format: "  resumeText again (warm): %.1f ms", msd(t)))
