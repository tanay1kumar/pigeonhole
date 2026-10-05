// Probe: PLAN §4.4 step 3 Vision-label mapping, as specified: surface word + plural-folded form (smaller distance wins),
// label word = whole label if in vocabulary else its last '_' part (half weight, never exact), keep d <= 0.9 or exact/plural,
// weight 1 - d/2 (exact 1.0), ranked by weight. Prints the top N (default 20) and the ranks of key labels.
// Run: swiftc -O tools/bench/probes/label_mapping.swift -o "$TMPDIR/label_mapping" && "$TMPDIR/label_mapping" 20

import Foundation
import NaturalLanguage
import Vision
// Implements PLAN §4.4 step 3 as now written: surface + folded form, keep smaller distance per label;
// label word = whole label if in vocab else last '_' part (half weight, never exact);
// keep d <= 0.9 plus exact/plural; weight 1 - d/2, exact 1.0; top 15 by weight.
let topN = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20 : 20
let words = NLEmbedding.wordEmbedding(for: .english)!
let taxonomy = try VNClassifyImageRequest().supportedIdentifiers()
func fold(_ w: String) -> String { (w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss")) ? String(w.dropLast()) : w }
func run(_ surface: String, useFolded: Bool) {
    let forms = useFolded ? Array(Set([surface, fold(surface)])) : [surface]
    var rows: [(label: String, d: Double, w: Double, exact: Bool, lastWord: Bool)] = []
    for label in taxonomy {
        var lw: String? = nil; var lastWord = false
        if words.contains(label) { lw = label } else if let last = label.split(separator: "_").last.map(String.init), words.contains(last) { lw = last; lastWord = true }
        guard let lab = lw else { continue }
        var best = Double.infinity; var exact = false
        for f in forms where words.contains(f) {
            let d = words.distance(between: f, and: lab)
            best = min(best, d)
            if !lastWord && (lab == f || lab + "s" == f || f + "s" == lab) { exact = true }
        }
        guard best.isFinite else { continue }
        guard best <= 0.9 || exact else { continue }
        var w = exact ? 1.0 : 1 - best / 2
        if lastWord { w /= 2 }
        rows.append((label, best, w, exact, lastWord))
    }
    rows.sort { $0.w > $1.w || ($0.w == $1.w && $0.label < $1.label) }
    let top = rows.prefix(topN)
    print("\(surface) useFolded=\(useFolded): kept \(rows.count); top\(topN):")
    print("   " + top.map { "\($0.label) \(String(format: "%.3f", $0.d))\($0.lastWord ? "(lw)" : "")" }.joined(separator: ", "))
    for l in ["flower", "lily", "rose", "dahlia", "daisy", "tulip", "sunflower", "dandelion"] {
        if let i = rows.firstIndex(where: { $0.label == l }) { print("   \(l): rank \(i + 1), d \(String(format: "%.3f", rows[i].d))\(i < topN ? "" : "  <-- OUTSIDE TOP \(topN)")") } else { print("   \(l): not kept") }
    }
}

run("flowers", useFolded: true)
run("receipts", useFolded: true)
run("resumes", useFolded: true)
run("pets", useFolded: true)
