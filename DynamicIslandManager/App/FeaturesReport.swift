import Foundation

// --features <file>... [--repeat N] [--idle S] [--diag-boxes]
// per file one first run then N warm runs, cache bypassed
// then waits S seconds (vision unloads) and runs each file again
enum FeaturesReport {
    // time budgets from the plan, warm p50 on an m3
    static func budget(for features: FileFeatures) -> Double {
        switch features.kind {
        case .image:
            guard features.ocrReason != nil else { return 60 }
            return features.textLength > 300 ? 250 : 150
        case .pdf:
            return features.ocrReason == "scanned pdf" ? 300 : 25
        case .richText, .text, .code:
            return 25
        default:
            return 5
        }
    }

    @MainActor
    static func run(paths: [String], repeats: Int, idle: Double, diagBoxes: Bool, prewarm: Bool = false) async -> Int32 {
        let urls = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            for url in missing {
                print("can't read \(url.path)")
            }
            return 2
        }

        let extractor = FeatureExtractor()
        var options = ExtractOptions()
        options.diagBoxes = diagBoxes

        struct Row {
            let name: String
            var kind = ""
            var first: Double = 0
            var warm: [Double] = []
            var afterIdle: Double?
            var budget: Double = 0
        }
        var rows: [Row] = []

        for url in urls {
            var row = Row(name: url.lastPathComponent)
            for run in 0...repeats {
                let features = await extractor.extract([url], options: options, useCache: false)[0]
                if run == 0 {
                    printDetails(features, url: url, label: "first run")
                    row.kind = features.kind.rawValue + (features.ocrReason != nil ? "+ocr" : "")
                    row.first = features.totalMs
                    row.budget = budget(for: features)
                } else {
                    print("  warm \(run): \(stageLine(features))")
                    row.warm.append(features.totalMs)
                }
            }
            rows.append(row)
        }

        if idle > 0 {
            print("\nidle \(idle) s (vision lets go of its memory)...")
            try? await Task.sleep(for: .seconds(idle))
            if prewarm {
                // same as a finder drag starting
                await extractor.prewarm(ocr: true)
            }
            for (index, url) in urls.enumerated() {
                let features = await extractor.extract([url], options: options, useCache: false)[0]
                print("after-idle \(url.lastPathComponent): \(stageLine(features))")
                rows[index].afterIdle = features.totalMs
            }
        }

        print("\nsummary (ms)          kind              first   warm p50  warm max  after-idle  budget")
        for row in rows {
            let sorted = row.warm.sorted()
            let name = String(row.name.prefix(22)).padding(toLength: 22, withPad: " ", startingAt: 0)
            let kind = row.kind.padding(toLength: 16, withPad: " ", startingAt: 0)
            let idle = (row.afterIdle.map { String(format: "%.1f", $0) } ?? "-")
            // budgets are for warm runs, nothing to grade without --repeat
            var warm = "       -         -"
            var verdict = "(no warm runs)"
            if !sorted.isEmpty {
                let p50 = sorted[(sorted.count - 1) / 2]
                warm = String(format: "%8.1f  %8.1f", p50, sorted.last!)
                verdict = p50 <= row.budget ? "ok" : "OVER"
            }
            print(name + " " + kind + String(format: " %7.1f  ", row.first) + warm + "  "
                  + String(repeating: " ", count: max(0, 10 - idle.count)) + idle + String(format: "  %5.0f ", row.budget) + verdict)
        }
        return 0
    }

    static func printDetails(_ features: FileFeatures, url: URL, label: String) {
        print("\n== \(url.lastPathComponent) (\(label))")
        var line = "kind: \(features.kind.rawValue)  ocr: \(features.ocrReason ?? "none")"
        if let size = features.classifySize {
            line += "  classified at \(Int(size.width))x\(Int(size.height))"
        }
        if let size = features.ocrSize {
            line += "  ocr image \(Int(size.width))x\(Int(size.height))"
        }
        if let boxes = features.textBoxes {
            line += "  text boxes @1600: \(boxes) (gate \(features.ocrReason == nil ? "closed" : "open"), not timed)"
        }
        if let error = features.error {
            line += "  ERROR \(error)"
        }
        if features.deadlineHit {
            line += "  DEADLINE HIT"
        }
        print(line)
        print("stages: \(stageLine(features))")
        let top = zip(features.sparse.indices, features.sparse.values)
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(15)
        print("top features:")
        for (index, value) in top {
            print(String(format: "  %-34@ %.3f", (features.names[index] ?? "#\(index)") as NSString, value))
        }
        if !features.labels.isEmpty {
            print("vision: " + features.labels.map { String(format: "%@ %.2f", $0.0 as NSString, $0.1) }.joined(separator: ", "))
        }
        print("dense: \(features.dense.map { "\($0.count)-d" } ?? "none")  summary: \(features.summary)")
        print("indices: \(features.sparse.indices.count) signature \(signature(features))")
    }

    // same file and build across two launches, this has to match
    static func signature(_ features: FileFeatures) -> String {
        let text = zip(features.sparse.indices, features.sparse.values)
            .map { "\($0.0):\(String(format: "%.6f", $0.1))" }
            .joined(separator: ",")
        return String(format: "%016llx", FeatureHash.fnv1a64(text))
    }

    static func stageLine(_ features: FileFeatures) -> String {
        let order = ["metadata", "thumbnail", "classify", "ocrImage", "pdfText", "pdfRender",
                     "richText", "readText", "ocr", "tokenize", "patterns", "vectorize", "embed"]
        var parts = order.compactMap { stage in features.timings[stage].map { String(format: "%@ %.1f", stage as NSString, $0) } }
        parts.append(String(format: "total %.1f", features.totalMs))
        return parts.joined(separator: "  ")
    }
}
