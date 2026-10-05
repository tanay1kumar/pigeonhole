import Foundation

// --eval <dir> [--hints hints.json] [--runs N] [--seed S] [--json out.json] [--params params.json] [--diag-boxes]
// (the plan §5 step 4) accuracy and speed on a folder of labelled files: <dir>/<Destination>/<files>.
// folders starting with "_" are controls (_none: files that belong nowhere). everything stays in memory:
// nothing is uploaded, nothing learned is saved, no user defaults are written.
// sections 1 and 3-5 are deterministic (same seed, same output); 2 and 6 are time and memory.
enum Eval {
    struct Options {
        var directory: URL
        var hintsURL: URL?
        var runs = 20
        var seed: UInt64 = 1
        var jsonURL: URL?
        var paramsURL: URL?
        var diagBoxes = false
    }

    struct Sample {
        let url: URL
        let folder: String           // destination name, or a control like "_none"
        let truth: Int?              // destination index, nil for controls
        var features: FileFeatures
        var ms: Double
    }

    // MARK: entry

    @MainActor
    static func run(_ options: Options) async -> Int32 {
        let startFootprint = physFootprintMB()
        var peakFootprint = startFootprint

        // params and hints
        var params = ScoringParams()
        if let paramsURL = options.paramsURL {
            guard let loaded = loadParams(paramsURL, into: params) else {
                print("couldn't read params from \(paramsURL.path)")
                return 2
            }
            params = loaded
        }
        var hints: [String: String] = [:]
        if let hintsURL = options.hintsURL {
            guard let data = try? Data(contentsOf: hintsURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                print("couldn't read hints from \(hintsURL.path)")
                return 2
            }
            hints = parsed
        }

        // layout: sorted folders, sorted files, hidden files and nested folders ignored
        guard let layout = scan(options.directory) else {
            print("can't read \(options.directory.path)")
            return 2
        }
        let destinations = layout.destinations.map { Destination(id: "eval:\($0)", name: $0, path: $0, hint: hints[$0]) }
        guard !destinations.isEmpty else {
            print("no destination folders in \(options.directory.path)")
            return 2
        }

        // unreadable files (tcc): stop before measuring anything
        let unreadable = layout.files.filter { !canRead($0.url) }
        if !unreadable.isEmpty {
            for file in unreadable {
                print("can't read \(file.url.path) (Desktop, Documents and Downloads need permission: copy the files elsewhere)")
            }
            return 2
        }

        // extract every file once, one at a time, so each time and the memory peak are its own
        let extractor = FeatureExtractor()
        var extractOptions = ExtractOptions()
        extractOptions.origin = "eval"     // the folder layout encodes the answer
        extractOptions.diagBoxes = options.diagBoxes
        var samples: [Sample] = []
        for file in layout.files {
            let started = DispatchTime.now()
            var features = await extractor.extract([file.url], options: extractOptions, useCache: false)[0]
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            if params.blockWeights != BlockWeights.standard {
                (features.sparse, features.names) = FeatureVectorizer.vectorize(features.raw, weights: params.blockWeights)
            }
            let truth = layout.destinations.firstIndex(of: file.folder)
            samples.append(Sample(url: file.url, folder: file.folder, truth: truth, features: features, ms: ms))
            peakFootprint = max(peakFootprint, physFootprintMB())
        }
        let afterExtraction = physFootprintMB()

        var report = Report()
        report.line("eval of \(options.directory.path)")
        report.line("destinations: " + destinations.map { destination in
            destination.hint.map { "\(destination.name) (hint: \($0))" } ?? destination.name
        }.joined(separator: ", "))
        report.line("params: \(describe(params)); runs \(options.runs), seed \(options.seed)")

        report.section(1, "files")
        countsSection(samples, destinations: destinations, layout: layout, report: &report)

        report.section(2, "extraction time (ms, not deterministic)")
        timingSection(samples, report: &report)

        report.section(3, "zero-shot (nothing learned)")
        let zeroShot = await zeroShotSection(samples, destinations: destinations, params: params, report: &report)

        report.section(4, "learning curve (k accepted examples per folder, test on the rest)")
        let curve = await curveSection(samples, destinations: destinations, params: params, options: options, report: &report)

        report.section("4b", "one folder learns (k examples into one folder only, everything else ranked)")
        let oneFolder = await oneFolderSection(samples, destinations: destinations, params: params, options: options, report: &report)

        report.section(5, "online simulation (predict, then learn: accepted if right, corrected if wrong)")
        let online = await onlineSection(samples, destinations: destinations, params: params, options: options, report: &report)

        report.section(6, "memory (phys_footprint MB, not deterministic)")
        report.line(String(format: "start %.1f, after extraction %.1f, peak %.1f (sampled after each file)",
                           startFootprint, afterExtraction, peakFootprint))

        print(report.text)

        if let jsonURL = options.jsonURL {
            let json: [String: Any] = ["zeroShot": zeroShot, "curve": curve, "oneFolder": oneFolder, "online": online,
                                       "files": samples.count, "params": describe(params)]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: jsonURL)
            }
        }
        return 0
    }

    // MARK: layout

    struct Layout {
        var destinations: [String] = []
        var controls: [String] = []
        var files: [(url: URL, folder: String)] = []
    }

    static func scan(_ directory: URL) -> Layout? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        var layout = Layout()
        for folder in folders.sorted() where !folder.hasPrefix(".") {
            let folderURL = directory.appendingPathComponent(folder).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if folder.hasPrefix("_") {
                layout.controls.append(folder)
            } else {
                layout.destinations.append(folder)
            }
            let names = (try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = folderURL.appendingPathComponent(name).resolvingSymlinksInPath()
                var nested: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &nested) else { continue }
                // nested folders are ignored, packages (.app, .pages) count as files
                if nested.boolValue && !((try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false) {
                    continue
                }
                layout.files.append((url, folder))
            }
        }
        return layout
    }

    static func canRead(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            return FileManager.default.isReadableFile(atPath: url.path)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }

    // MARK: 1. counts and leaks

    static func countsSection(_ samples: [Sample], destinations: [Destination], layout: Layout, report: inout Report) {
        for folder in layout.destinations + layout.controls {
            let inFolder = samples.filter { $0.folder == folder }
            var kinds: [String: Int] = [:]
            for sample in inFolder {
                kinds[sample.features.kind.rawValue, default: 0] += 1
            }
            let kindText = kinds.keys.sorted().map { "\($0) \(kinds[$0]!)" }.joined(separator: ", ")
            report.line("\(pad(folder, 12)) \(inFolder.count) files: \(kindText)")
        }
        // a file named after its folder (or the folder's pack) is too easy, flag it
        var leaks: [String] = []
        for sample in samples {
            guard let truth = sample.truth else { continue }
            let destination = destinations[truth]
            let fileWords = Set(TokenNormalizer.filenameWords(sample.url.lastPathComponent).compactMap { TokenNormalizer.normalize($0, keepDigits: true) })
            var clues = Set(TokenNormalizer.words(destination.name).compactMap { TokenNormalizer.normalize($0, keepDigits: true) })
            let words = Array(clues)
            for pack in KeywordPacks.matches(words: words, name: destination.name) {
                for trigger in pack.triggers where !trigger.contains(" ") {
                    if let token = TokenNormalizer.normalize(trigger, keepDigits: true) {
                        clues.insert(token)
                    }
                }
            }
            let hit = fileWords.intersection(clues).sorted()
            if !hit.isEmpty {
                leaks.append("\(sample.folder)/\(sample.url.lastPathComponent) (\(hit.joined(separator: ", ")))")
            }
        }
        report.line("name leaks (the name gives the answer away): " + (leaks.isEmpty ? "none" : "\(leaks.count)"))
        for leak in leaks {
            report.line("  \(leak)")
        }
    }

    // MARK: 2. timing

    static func timingSection(_ samples: [Sample], report: inout Report) {
        var byKind: [String: [Double]] = [:]
        var reasons: [String: Int] = [:]
        for sample in samples {
            let kind = sample.features.kind.rawValue + (sample.features.ocrReason != nil ? "+ocr" : "")
            byKind[kind, default: []].append(sample.ms)
            if let reason = sample.features.ocrReason {
                reasons[reason, default: 0] += 1
            }
        }
        report.line("\(pad("kind", 14)) \(pad("n", 4)) \(pad("cold", 8)) \(pad("p50", 8)) \(pad("p95", 8)) max")
        for kind in byKind.keys.sorted() {
            let times = byKind[kind]!
            let sorted = times.sorted()
            report.line("\(pad(kind, 14)) \(pad("\(times.count)", 4)) \(pad(format(times[0]), 8)) \(pad(format(percentile(sorted, 0.5)), 8)) \(pad(format(percentile(sorted, 0.95)), 8)) \(format(sorted.last!))")
        }
        let ocrCount = reasons.values.reduce(0, +)
        report.line("ocr on \(ocrCount) file(s): " + (reasons.isEmpty ? "none" : reasons.keys.sorted().map { "\($0) \(reasons[$0]!)" }.joined(separator: ", ")))
        let boxes = samples.compactMap { sample in sample.features.textBoxes.map { (sample, $0) } }
        if !boxes.isEmpty {
            report.line("text boxes at 1600 px (--diag-boxes):")
            for (sample, count) in boxes {
                report.line("  \(pad(sample.folder + "/" + sample.url.lastPathComponent, 40)) \(pad("\(count)", 4)) gate \(sample.features.ocrReason ?? "closed")")
            }
        }
    }

    // MARK: 3. zero-shot

    static func zeroShotSection(_ samples: [Sample], destinations: [Destination], params: ScoringParams,
                                report: inout Report) async -> [String: Any] {
        let classifier = DestinationClassifier(store: LearningStore(fileURL: nil), params: params)
        var stats = LevelStats()
        var confusion = [[Int]](repeating: [Int](repeating: 0, count: destinations.count), count: destinations.count)
        var perFolder = [(correct: Int, total: Int)](repeating: (0, 0), count: destinations.count)
        var noneLevels: [Level: Int] = [:]
        var noneTop: [String] = []
        var wrongConfident: [String] = []
        var notConfident: [String] = []

        for sample in samples {
            let ranking = await classifier.rank(sample.features, among: destinations)
            let top = destinations.firstIndex { $0.id == ranking.items[0].destination.id }!
            guard let truth = sample.truth else {
                noneLevels[ranking.level, default: 0] += 1
                if ranking.level != .noIdea {
                    noneTop.append("\(sample.url.lastPathComponent) -> \(destinations[top].name) (\(ranking.level.rawValue))")
                }
                continue
            }
            let topThree = ranking.items.prefix(3).map { item in destinations.firstIndex { $0.id == item.destination.id }! }
            stats.add(level: ranking.level, correct: top == truth, inTopThree: topThree.contains(truth))
            confusion[truth][top] += 1
            perFolder[truth].total += 1
            if top == truth {
                perFolder[truth].correct += 1
            } else if ranking.level == .confident {
                wrongConfident.append("\(sample.folder)/\(sample.url.lastPathComponent) -> \(destinations[top].name)")
            }
            if ranking.level != .confident {
                notConfident.append("\(sample.folder)/\(sample.url.lastPathComponent) -> \(destinations[top].name) (\(ranking.level.rawValue), \"\(ranking.why)\")")
            }
        }

        let macro = macroAccuracy(perFolder)
        report.line("top-1: \(rate(stats.correct, stats.total)) micro, \(percent(macro)) macro")
        for (index, destination) in destinations.enumerated() {
            report.line("  \(pad(destination.name, 12)) \(rate(perFolder[index].correct, perFolder[index].total))")
        }
        report.line("confusion (rows: true folder, columns: top-1):")
        report.line("  \(pad("", 12)) " + destinations.map { pad(String($0.name.prefix(8)), 9) }.joined())
        for (index, row) in confusion.enumerated() {
            report.line("  \(pad(destinations[index].name, 12)) " + row.map { pad("\($0)", 9) }.joined())
        }
        stats.print(into: &report)
        for line in notConfident {
            report.line("  not confident: \(line)")
        }
        report.line("wrong confident: " + (wrongConfident.isEmpty ? "none" : wrongConfident.joined(separator: "; ")))
        let noneTotal = noneLevels.values.reduce(0, +)
        report.line("controls (_ folders): \(noneTotal) files: confident \(noneLevels[.confident] ?? 0), unsure \(noneLevels[.unsure] ?? 0), no idea \(rate(noneLevels[.noIdea] ?? 0, noneTotal))")
        for line in noneTop {
            report.line("  \(line)")
        }
        return ["micro": ratio(stats.correct, stats.total), "macro": macro, "levels": stats.json(),
                "wrongConfident": wrongConfident.count, "controlsConfident": noneLevels[.confident] ?? 0,
                "controlsNoIdea": ratio(noneLevels[.noIdea] ?? 0, noneTotal)]
    }

    // MARK: 4. learning curve

    static func curveSection(_ samples: [Sample], destinations: [Destination], params: ScoringParams,
                             options: Options, report: inout Report) async -> [String: Any] {
        var result: [String: Any] = [:]
        let byFolder = destinations.indices.map { index in samples.filter { $0.truth == index } }
        let controls = samples.filter { $0.truth == nil }
        for k in [1, 3, 5] {
            var stats = LevelStats()
            var perFolder = [(correct: Int, total: Int)](repeating: (0, 0), count: destinations.count)
            var controlLevels: [Level: Int] = [:]
            var controlDetail: [String: Int] = [:]     // "file -> destination (level)" counts
            var kPerFolder: [Int] = []
            for run in 0..<options.runs {
                var rng = SplitMix64(seed: options.seed &+ UInt64(run))
                let store = LearningStore(fileURL: nil)
                let classifier = DestinationClassifier(store: store, params: params)
                var tests: [Sample] = []
                kPerFolder = []
                for (index, files) in byFolder.enumerated() {
                    guard files.count > 1 else {
                        kPerFolder.append(0)
                        continue
                    }
                    let shuffled = rng.shuffled(files)
                    let kf = min(k, files.count - 1)
                    kPerFolder.append(kf)
                    let batch = UUID()
                    store.record(shuffled.prefix(kf).map {
                        LearningEvent(batchId: batch, sparse: $0.features.sparse, dense: $0.features.dense,
                                      chosenId: destinations[index].id, suggestedId: destinations[index].id,
                                      level: .confident, kind: .accepted)
                    })
                    tests.append(contentsOf: shuffled.dropFirst(kf))
                }
                for sample in tests {
                    guard let truth = sample.truth else { continue }
                    let ranking = await classifier.rank(sample.features, among: destinations)
                    let top = destinations.firstIndex { $0.id == ranking.items[0].destination.id }!
                    let topThree = ranking.items.prefix(3).map { item in destinations.firstIndex { $0.id == item.destination.id }! }
                    stats.add(level: ranking.level, correct: top == truth, inTopThree: topThree.contains(truth))
                    perFolder[truth].total += 1
                    if top == truth {
                        perFolder[truth].correct += 1
                    }
                }
                for sample in controls {
                    let ranking = await classifier.rank(sample.features, among: destinations)
                    controlLevels[ranking.level, default: 0] += 1
                    if ranking.level != .noIdea {
                        controlDetail["\(sample.url.lastPathComponent) -> \(ranking.items[0].destination.name) (\(ranking.level.rawValue))", default: 0] += 1
                    }
                }
            }
            let macro = macroAccuracy(perFolder)
            let kText = zip(destinations, kPerFolder).map { "\($0.name) \($1)" }.joined(separator: ", ")
            report.line("k = \(k) (k per folder: \(kText)), \(options.runs) runs pooled")
            report.line("  top-1 \(rate(stats.correct, stats.total)) micro, \(percent(macro)) macro; confident precision \(rate(stats.confidentCorrect, stats.confident)), coverage \(rate(stats.confident, stats.total))")
            let perText = destinations.indices.map { "\(destinations[$0].name) \(percent(ratio(perFolder[$0].correct, perFolder[$0].total)))" }
            report.line("  per folder: " + perText.joined(separator: ", "))
            let controlTotal = controlLevels.values.reduce(0, +)
            if controlTotal > 0 {
                report.line("  controls: confident \(controlLevels[.confident] ?? 0), unsure \(controlLevels[.unsure] ?? 0), no idea \(rate(controlLevels[.noIdea] ?? 0, controlTotal))")
                for key in controlDetail.keys.sorted() {
                    report.line("    \(key) x\(controlDetail[key]!)")
                }
            }
            var perFolderJSON: [String: Double] = [:]
            for (index, destination) in destinations.enumerated() {
                perFolderJSON[destination.name] = ratio(perFolder[index].correct, perFolder[index].total)
            }
            result["k\(k)"] = ["micro": ratio(stats.correct, stats.total), "macro": macro,
                               "confidentPrecision": ratio(stats.confidentCorrect, stats.confident),
                               "coverage": ratio(stats.confident, stats.total), "perFolder": perFolderJSON,
                               "controlsConfident": controlLevels[.confident] ?? 0]
        }
        return result
    }

    // MARK: 4b. one folder learns

    // real use starts with one folder learning while the others know nothing. what every photo or pdf
    // shares must not carry other files to that folder at "confident"
    static func oneFolderSection(_ samples: [Sample], destinations: [Destination], params: ScoringParams,
                                 options: Options, report: inout Report) async -> [String: Any] {
        var result: [String: Any] = [:]
        let byFolder = destinations.indices.map { index in samples.filter { $0.truth == index } }
        for k in [1, 3] {
            var own = (confident: 0, total: 0)
            var wrong = 0, others = 0
            var perFolder: [String: Any] = [:]
            var detail: [String: Int] = [:]
            for (index, files) in byFolder.enumerated() where files.count > 1 {
                let destination = destinations[index]
                let kf = min(k, files.count - 1)
                var folderOwn = (confident: 0, total: 0)
                var folderWrong = 0
                for run in 0..<options.runs {
                    var rng = SplitMix64(seed: options.seed &+ UInt64(run) &+ (UInt64(index) << 32))
                    let store = LearningStore(fileURL: nil)
                    let classifier = DestinationClassifier(store: store, params: params)
                    let shuffled = rng.shuffled(files)
                    let batch = UUID()
                    store.record(shuffled.prefix(kf).map {
                        LearningEvent(batchId: batch, sparse: $0.features.sparse, dense: $0.features.dense,
                                      chosenId: destination.id, suggestedId: destination.id, level: .confident, kind: .accepted)
                    })
                    for sample in shuffled.dropFirst(kf) {
                        let ranking = await classifier.rank(sample.features, among: destinations)
                        folderOwn.total += 1
                        if ranking.level == .confident && ranking.items[0].destination.id == destination.id {
                            folderOwn.confident += 1
                        }
                    }
                    for sample in samples where sample.truth != index {
                        let ranking = await classifier.rank(sample.features, among: destinations)
                        others += 1
                        if ranking.level == .confident && ranking.items[0].destination.id == destination.id {
                            folderWrong += 1
                            detail["\(sample.url.lastPathComponent) -> \(destination.name)", default: 0] += 1
                        }
                    }
                }
                own.confident += folderOwn.confident
                own.total += folderOwn.total
                wrong += folderWrong
                report.line("k = \(k) into \(destination.name) only (\(kf) each run): its other files confident \(rate(folderOwn.confident, folderOwn.total)); other files confident -> \(destination.name): \(folderWrong)")
                perFolder[destination.name] = ["ownConfident": ratio(folderOwn.confident, folderOwn.total), "wrongConfident": folderWrong]
            }
            report.line("  k = \(k), \(options.runs) runs per folder: wrong confident \(wrong) of \(others) rankings of other files; own files confident \(rate(own.confident, own.total))")
            for key in detail.keys.sorted() {
                report.line("    \(key) (confident) x\(detail[key]!)")
            }
            result["k\(k)"] = ["wrongConfident": wrong, "ownConfident": ratio(own.confident, own.total), "perFolder": perFolder]
        }
        return result
    }

    // MARK: 5. online simulation

    static func onlineSection(_ samples: [Sample], destinations: [Destination], params: ScoringParams,
                              options: Options, report: inout Report) async -> [String: Any] {
        let labelled = samples.filter { $0.truth != nil }
        let checkpoints = [0.25, 0.5, 0.75, 1.0].map { max(1, Int((Double(labelled.count) * $0).rounded())) }
        var correctAt = [Int](repeating: 0, count: checkpoints.count)
        var totalAt = [Int](repeating: 0, count: checkpoints.count)
        var confident = 0, confidentCorrect = 0
        for run in 0..<options.runs {
            var rng = SplitMix64(seed: options.seed &+ UInt64(run))
            let order = rng.shuffled(labelled)
            let store = LearningStore(fileURL: nil)
            let classifier = DestinationClassifier(store: store, params: params)
            var correctSoFar = 0
            for (position, sample) in order.enumerated() {
                guard let truth = sample.truth else { continue }
                let ranking = await classifier.rank(sample.features, among: destinations)
                let top = destinations.firstIndex { $0.id == ranking.items[0].destination.id }!
                let right = top == truth
                if right {
                    correctSoFar += 1
                }
                if ranking.level == .confident {
                    confident += 1
                    if right {
                        confidentCorrect += 1
                    }
                }
                store.record([LearningEvent(batchId: UUID(), sparse: sample.features.sparse, dense: sample.features.dense,
                                            chosenId: destinations[truth].id, suggestedId: destinations[top].id,
                                            level: ranking.level, kind: right ? .accepted : .corrected)])
                for (index, checkpoint) in checkpoints.enumerated() where position + 1 == checkpoint {
                    correctAt[index] += correctSoFar
                    totalAt[index] += checkpoint
                }
            }
        }
        let labels = ["25%", "50%", "75%", "100%"]
        let parts = labels.indices.map { "\(labels[$0]) \(rate(correctAt[$0], totalAt[$0]))" }
        report.line("cumulative top-1 over \(labelled.count) files, \(options.runs) shuffles: " + parts.joined(separator: ", "))
        report.line("confident precision while learning: \(rate(confidentCorrect, confident))")
        var json: [String: Double] = [:]
        for index in labels.indices {
            json[labels[index]] = ratio(correctAt[index], totalAt[index])
        }
        return ["cumulative": json, "confidentPrecision": ratio(confidentCorrect, confident)]
    }

    // MARK: helpers

    struct LevelStats {
        var total = 0, correct = 0
        var confident = 0, confidentCorrect = 0
        var unsure = 0, unsureCorrect = 0, unsureTopThree = 0
        var noIdea = 0, noIdeaCorrect = 0

        mutating func add(level: Level, correct right: Bool, inTopThree: Bool) {
            total += 1
            if right { correct += 1 }
            switch level {
            case .confident:
                confident += 1
                if right { confidentCorrect += 1 }
            case .unsure:
                unsure += 1
                if right { unsureCorrect += 1 }
                if inTopThree { unsureTopThree += 1 }
            case .noIdea:
                noIdea += 1
                if right { noIdeaCorrect += 1 }
            }
        }

        func print(into report: inout Report) {
            report.line("levels: confident coverage \(Eval.rate(confident, total)), precision \(Eval.rate(confidentCorrect, confident))")
            report.line("        unsure coverage \(Eval.rate(unsure, total)), precision \(Eval.rate(unsureCorrect, unsure)), top-3 hit \(Eval.rate(unsureTopThree, unsure))")
            report.line("        no idea coverage \(Eval.rate(noIdea, total)), top-1 anyway \(Eval.rate(noIdeaCorrect, noIdea))")
        }

        func json() -> [String: Double] {
            ["confidentCoverage": Eval.ratio(confident, total), "confidentPrecision": Eval.ratio(confidentCorrect, confident),
             "unsureCoverage": Eval.ratio(unsure, total), "unsurePrecision": Eval.ratio(unsureCorrect, unsure),
             "unsureTopThree": Eval.ratio(unsureTopThree, unsure), "noIdeaCoverage": Eval.ratio(noIdea, total)]
        }
    }

    struct Report {
        private(set) var text = ""
        mutating func line(_ string: String) {
            text += string + "\n"
        }
        mutating func section(_ number: Int, _ title: String) {
            section(String(number), title)
        }
        mutating func section(_ label: String, _ title: String) {
            text += "\n== \(label). \(title)\n"
        }
    }

    static func ratio(_ part: Int, _ whole: Int) -> Double {
        whole == 0 ? 0 : Double(part) / Double(whole)
    }

    static func rate(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "n/a (0/0)" : String(format: "%.1f%% (%d/%d)", 100 * Double(part) / Double(whole), part, whole)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", 100 * value)
    }

    static func macroAccuracy(_ perFolder: [(correct: Int, total: Int)]) -> Double {
        let folders = perFolder.filter { $0.total > 0 }
        guard !folders.isEmpty else { return 0 }
        return folders.map { ratio($0.correct, $0.total) }.reduce(0, +) / Double(folders.count)
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[index]
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? string + " " : string.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    static func describe(_ params: ScoringParams) -> String {
        var parts = [String(format: "alpha %.2f beta %.2f lambdaK %.2f lambdaE %.2f T %.3f p1 %.2f margin %.2f floor %.2f unsure %.2f labels %d",
                            params.alpha, params.beta, params.lambdaKScale, params.lambdaE, params.temperature,
                            params.confidentP1, params.confidentMargin, params.confidentFloor, params.unsureFloor, params.labelCap)]
        if params.blockWeights != BlockWeights.standard {
            parts.append("weights " + params.blockWeights.weights.keys.sorted().map { "\($0) \(params.blockWeights.weights[$0]!)" }.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    // {"alpha": 2, ..., "blockWeights": {"c": 1, ...}}; missing keys keep their defaults
    static func loadParams(_ url: URL, into base: ScoringParams) -> ScoringParams? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var params = base
        func float(_ key: String) -> Float? { (json[key] as? NSNumber)?.floatValue }
        if let value = float("alpha") { params.alpha = value }
        if let value = float("beta") { params.beta = value }
        if let value = float("lambdaKScale") { params.lambdaKScale = value }
        if let value = float("lambdaE") { params.lambdaE = value }
        if let value = float("temperature") { params.temperature = value }
        if let value = float("confidentP1") { params.confidentP1 = value }
        if let value = float("confidentMargin") { params.confidentMargin = value }
        if let value = float("confidentFloor") { params.confidentFloor = value }
        if let value = float("unsureFloor") { params.unsureFloor = value }
        if let value = (json["labelCap"] as? NSNumber)?.intValue { params.labelCap = value }
        if let weights = json["blockWeights"] as? [String: NSNumber] {
            for (namespace, weight) in weights {
                params.blockWeights.weights[namespace] = weight.floatValue
            }
        }
        return params
    }
}

// splitmix64: the same seed gives the same shuffles on every machine
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    // fisher-yates
    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var result = items
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            let other = Int(next() % UInt64(index + 1))
            result.swapAt(index, other)
        }
        return result
    }
}

// what activity monitor, footprint and top's MEM show (the plan §7.5)
// "memory: <when> <MB>" in the log (the plan §4.8 footprint targets)
func logMemory(_ when: String) {
    print(String(format: "memory: %@ %.1f MB", when, physFootprintMB()))
}

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    // TASK_VM_INFO_COUNT isn't imported into swift; compute it
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
