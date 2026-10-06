#if DEBUG
import Foundation

// --selftest write | verify
// write: temp store, print profiles, rank samples, learn, undo, save
// verify (second launch): saved data matches, then removeData and reset
// only uses $TMPDIR/dim-selftest, never the real learning.json
enum SelfTest {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dim-selftest", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("learning.json") }
    static var expectURL: URL { directory.appendingPathComponent("expect.json") }
    static var fullCapsURL: URL { directory.appendingPathComponent("fullcaps.json") }

    static func destination(_ name: String, hint: String? = nil) -> Destination {
        Destination(id: "selftest:\(name)", name: name, path: name, hint: hint)
    }

    static let flowers = destination("Flowers")
    static let receipts = destination("Receipts")
    static let resumes = destination("Resumes")
    static let misc = destination("Misc")
    static let stuff = destination("Stuff")
    static var all: [Destination] { [flowers, receipts, resumes, misc, stuff] }

    @MainActor
    static func run(mode: String) async -> Int32 {
        let real = LearningStore.defaultURL.resolvingSymlinksInPath().path
        guard fileURL.resolvingSymlinksInPath().path != real else {
            print("refusing: the selftest path is the real learning file")
            return 2
        }
        let checks = Checks()
        switch mode {
        case "write":
            await write(checks)
        case "verify":
            await verify(checks)
        default:
            print("usage: --selftest write|verify")
            return 2
        }
        return checks.finish()
    }

    // MARK: write

    @MainActor
    static func write(_ checks: Checks) async {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LearningStore(fileURL: fileURL)
        let classifier = DestinationClassifier(store: store)
        let extractor = FeatureExtractor()

        print("== profiles")
        for destination in [flowers, receipts, resumes, misc] {
            let profile = await classifier.profileFor(destination)
            let labels = profile.visionLabels.map { String(format: "%@ %.2f", $0.0 as NSString, $0.1) }
            print("\(destination.name): packs [\(profile.packs.joined(separator: ", "))]  \(profile.visionLabels.count) labels: \(labels.joined(separator: ", "))")
        }
        let flowerLabels = Set(await classifier.profileFor(flowers).visionLabels.map(\.0))
        let wanted: Set<String> = ["flower", "lily", "rose", "dahlia", "daisy", "tulip", "sunflower", "dandelion"]
        checks.expect(wanted.isSubset(of: flowerLabels), "Flowers maps to \(wanted.sorted()) (missing \(wanted.subtracting(flowerLabels).sorted()))")
        checks.expect(flowerLabels.count == 22, "Flowers keeps 22 labels (\(flowerLabels.count))")
        let receiptLabels = await classifier.profileFor(receipts).visionLabels.map(\.0)
        checks.expect(receiptLabels == ["receipt"], "Receipts maps to receipt only (\(receiptLabels))")
        let resumeProfile = await classifier.profileFor(resumes)
        checks.expect(resumeProfile.visionLabels.isEmpty, "Resumes maps to no labels")
        checks.expect(resumeProfile.packs == ["resumes"], "Resumes gets the resumes pack (\(resumeProfile.packs))")
        let miscProfile = await classifier.profileFor(misc)
        checks.expect(miscProfile.vector.isEmpty && miscProfile.packs.isEmpty && miscProfile.visionLabels.isEmpty, "Misc maps to nothing")

        print("\n== built-in feature sets")
        let samples = await builtInSamples(extractor)
        for (name, features, expected) in samples {
            let ranking = await classifier.rank(features, among: [flowers, receipts, resumes, misc])
            let top = ranking.items[0]
            let list = ranking.items.prefix(4).map { String(format: "%@ %.3f", $0.destination.name as NSString, $0.raw) }.joined(separator: ", ")
            print("\(name): \(ranking.level.rawValue) -> \(top.destination.name)  why \"\(ranking.why)\"  [\(list)]")
            if let expected {
                checks.expect(top.destination.name == expected, "\(name) ranks \(expected) first")
            }
            checks.expect(!(top.destination.name == "Misc" && ranking.level == .confident), "Misc is never a confident top-1 (\(name))")
        }
        let sunflower = samples[0].1
        let sunflowerRanking = await classifier.rank(sunflower, among: [flowers, receipts, resumes, misc])
        checks.expect(sunflowerRanking.why.hasPrefix("looks like:") && sunflowerRanking.why.contains("flower"), "sunflower why reads \"looks like: …flower…\" (\(sunflowerRanking.why))")
        let resumeRanking = await classifier.rank(samples[2].1, among: [flowers, receipts, resumes, misc])
        checks.expect(resumeRanking.why.contains("mentions:"), "resume why mentions words (\(resumeRanking.why))")
        let songRanking = await classifier.rank(samples[3].1, among: [flowers, receipts, resumes, misc])
        checks.expect(songRanking.level == .noIdea, "song.mp3 is no idea (\(songRanking.level.rawValue))")

        print("\n== learning")
        let scenes = ["castle_scene.blend", "forest_scene.blend", "city_scene.blend", "harbor_scene.blend"]
        var sceneFeatures: [FileFeatures] = []
        for scene in scenes {
            sceneFeatures.append(sceneFile(scene))
        }
        let before = await classifier.rank(sceneFeatures[3], among: all)
        print("before: \(before.level.rawValue) -> \(before.items[0].destination.name)")
        let batch = UUID()
        await classifier.record(sceneFeatures.prefix(3).map {
            LearningEvent(batchId: batch, sparse: $0.sparse, dense: $0.dense, chosenId: stuff.id, suggestedId: nil, level: .noIdea, kind: .pickedAtNoIdea)
        })
        let after = await classifier.rank(sceneFeatures[3], among: all)
        print("after 3 into Stuff: \(after.level.rawValue) -> \(after.items[0].destination.name)  why \"\(after.why)\"")
        checks.expect(after.items[0].destination.id == stuff.id, "a 4th similar file ranks Stuff first")

        // correction, this harbor file goes in misc so the next one should too
        let harborFinal = sceneFile("harbor_scene_final.blend")
        let suggested = await classifier.rank(harborFinal, among: all).items[0].destination
        await classifier.record([LearningEvent(batchId: UUID(), sparse: harborFinal.sparse, dense: harborFinal.dense, chosenId: misc.id,
                                               suggestedId: suggested.id, level: .unsure, kind: .corrected)])
        let next = await classifier.rank(sceneFile("harbor_scene_v3.blend"), among: all)
        print("after correcting to Misc: \(next.level.rawValue) -> \(next.items[0].destination.name)")
        checks.expect(next.items[0].destination.id == misc.id, "a correction moves the next similar file to the corrected folder")

        // undo a 3 file batch, back to before plus one negative per file where it went
        // flowers keeps an earlier dense example so the restore has something to check
        let pressed = textFile("pressed_flowers_notes.txt", "pressing flowers between book pages, drying petals, framing the bouquet")
        await classifier.record([LearningEvent(batchId: UUID(), sparse: pressed.sparse, dense: pressed.dense, chosenId: flowers.id,
                                               suggestedId: flowers.id, level: .confident, kind: .accepted)])
        let beforeUndo = store.snapshot()
        checks.expect(beforeUndo[flowers.id]?.denseSum != nil, "Flowers has a dense sum before the batch")
        let threeFiles = [("geology_trip.txt", "rock layers fossils quarry map compass sediment"),
                          ("violin_lessons.txt", "bow strings scales etude recital tuning practice"),
                          ("garden_plans.txt", "seedlings compost raised beds tomatoes watering schedule")].map { textFile($0.0, $0.1) }
        let targets = [flowers, receipts, resumes]
        let undoBatch = UUID()
        await classifier.record(zip(threeFiles, targets).map { file, destination in
            LearningEvent(batchId: undoBatch, sparse: file.sparse, dense: file.dense, chosenId: destination.id,
                          suggestedId: destination.id, level: .confident, kind: .accepted)
        })
        let undone = await classifier.undoLastBatch()
        let afterUndo = store.snapshot()
        checks.expect(undone, "undo found the batch")
        var restored = true
        for destination in all {
            let old = beforeUndo[destination.id], new = afterUndo[destination.id]
            if (old?.examples.map(\.vector) ?? []) != (new?.examples.map(\.vector) ?? []) { restored = false }
            if !sameDense(old?.denseSum, new?.denseSum) || abs((old?.denseWeight ?? 0) - (new?.denseWeight ?? 0)) > 1e-4 { restored = false }
        }
        checks.expect(restored, "undo restores examples and dense sums")
        // one new negative per file on the folder it went to, none anywhere else
        var negativesRight = true
        for destination in all {
            let oldCount = beforeUndo[destination.id]?.negatives.count ?? 0
            let added = (afterUndo[destination.id]?.negatives ?? []).dropFirst(oldCount).map(\.vector)
            let expected = zip(threeFiles, targets).filter { $0.1.id == destination.id }.map { LearningStore.storedForm($0.0.sparse) }
            if added != expected { negativesRight = false }
        }
        checks.expect(negativesRight, "undo adds one negative per file, on the folder it went to")

        // what the second launch should find
        await classifier.flush()
        let saved = store.snapshot()
        var expect: [String: [String: Any]] = [:]
        for (id, data) in saved {
            expect[id] = ["examples": data.examples.count, "negatives": data.negatives.count, "denseWeight": Double(data.denseWeight),
                          "signature": signature(data), "dense": denseDigest(data)]
        }
        let expectData = try? JSONSerialization.data(withJSONObject: expect, options: [.sortedKeys])
        try? expectData?.write(to: expectURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        checks.expect(size > 0, "learning.json written (\(size) bytes)")

        print("\n== full caps")
        let full = LearningStore(fileURL: fullCapsURL)
        full.fillToCaps(destinationIds: (1...8).map { "full:\($0)" })
        let fullSize = (try? FileManager.default.attributesOfItem(atPath: fullCapsURL.path)[.size] as? Int) ?? 0
        print("fullcaps.json: \(fullSize) bytes (8 destinations x (100 examples + 50 negatives), 100 features each, dense sums)")
        checks.expect(fullSize > 0 && fullSize < 1_000_000, "full caps under 1,000,000 bytes")
    }

    // MARK: verify

    @MainActor
    static func verify(_ checks: Checks) async {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let expectData = try? Data(contentsOf: expectURL),
              let expect = try? JSONSerialization.jsonObject(with: expectData) as? [String: [String: Any]] else {
            print("run --selftest write first")
            checks.expect(false, "write ran first")
            return
        }
        let store = LearningStore(fileURL: fileURL)
        checks.expect(store.loadNote == "loaded", "file loads cleanly (\(store.loadNote))")
        let loaded = store.snapshot()
        checks.expect(Set(loaded.keys) == Set(expect.keys), "same destinations after relaunch")
        for (id, values) in expect {
            guard let data = loaded[id] else { continue }
            let same = data.examples.count == values["examples"] as? Int
                && data.negatives.count == values["negatives"] as? Int
                && abs(Double(data.denseWeight) - (values["denseWeight"] as? Double ?? -1)) < 1e-4
                && signature(data) == values["signature"] as? String
                && denseDigest(data) == values["dense"] as? String
            checks.expect(same, "\(id) matches after relaunch")
        }

        let classifier = DestinationClassifier(store: store)
        let ranking = await classifier.rank(sceneFile("harbor_scene.blend"), among: all)
        checks.expect(ranking.items[0].destination.id == stuff.id || ranking.items[0].destination.id == misc.id,
                      "learned destinations still win after relaunch (\(ranking.items[0].destination.name))")

        await classifier.removeData(for: stuff.id)
        checks.expect(store.data(for: stuff.id) == nil, "removeData drops Stuff")
        let reread = LearningStore(fileURL: fileURL)
        checks.expect(reread.data(for: stuff.id) == nil && reread.data(for: misc.id) != nil, "the file no longer has Stuff, keeps the rest")

        await classifier.reset()
        checks.expect(store.snapshot().isEmpty, "reset empties the store")
        checks.expect(!FileManager.default.fileExists(atPath: fileURL.path), "reset deletes learning.json")
    }

    // MARK: samples

    // same tokenizing and patterns as the extractor, on fixed text
    @MainActor
    static func builtInSamples(_ extractor: FeatureExtractor) async -> [(String, FileFeatures, String?)] {
        var sunflower: [String: Float] = ["v:flower": 0.94, "v:plant": 0.94, "v:sunflower": 0.94,
                                          "kind:image": 1, "ext:heic": 1, "n:sunflower": 1, "size:lt100k": 1]
        sunflower["from:selftest"] = 1
        let receipt = textRaw("""
            TRADER JOE'S #552 123 MAIN ST BANANAS 0.99 OAT MILK 3.49 COFFEE BEANS 8.99
            SUBTOTAL 13.47 TAX 1.08 TOTAL $14.55 VISA ****1234 THANK YOU FOR SHOPPING
            """, extra: ["kind:image": 1, "ext:png": 1, "n:scan": 1, "name:scan": 1, "size:lt1m": 1])
        let resume = textRaw("""
            Jordan Lee. Software engineering intern. Experience: built iOS features at a startup, wrote Python data
            pipelines. Education: Bachelor of Computer Science, University of Waterloo, GPA 3.8. Skills: Swift,
            Python, SQL, Git. References available on request. Objective: full-time role in mobile engineering.
            """, extra: ["kind:pdf": 1, "ext:pdf": 1, "n:doc": 1, "n:final": 1, "name:version": 1, "size:lt1m": 1])
        let song: [String: Float] = ["kind:audio": 1, "ext:mp3": 1, "n:song": 1, "size:lt100k": 1]

        var result: [(String, FileFeatures, String?)] = []
        for (name, raw, expected, summary) in [("Sunflower labels", sunflower, "Flowers", "sunflower flower plant"),
                                               ("receipt text", receipt, "Receipts", "scan total subtotal tax visa"),
                                               ("resume text", resume, "Resumes", "doc final experience education skills"),
                                               ("song.mp3", song, nil as String?, "song")] {
            var features = FileFeatures()
            (features.sparse, features.names) = FeatureVectorizer.vectorize(raw)
            features.kind = name == "song.mp3" ? .audio : name == "resume text" ? .pdf : .image
            features.dense = await extractor.embed(summary)
            result.append((name, features, expected))
        }
        return result
    }

    static func textRaw(_ text: String, extra: [String: Float]) -> [String: Float] {
        var counts: [String: Int] = [:]
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let token = TokenNormalizer.normalize(String(word)) {
                counts[token, default: 0] += 1
            }
        }
        var raw = extra
        for (token, count) in counts {
            raw["c:\(token)"] = Float(log(1 + Double(count)))
        }
        for pattern in FilePatterns.contentPatterns(text) {
            raw["pat:\(pattern)"] = 1
        }
        return raw
    }

    static func sceneFile(_ name: String) -> FileFeatures {
        var raw: [String: Float] = ["kind:other": 1, "ext:blend": 1, "size:lt10m": 1]
        for word in TokenNormalizer.filenameWords(name) {
            if let token = TokenNormalizer.normalize(word) {
                raw["n:\(token)"] = 1
            }
        }
        for pattern in FilePatterns.namePatterns(name) {
            raw["name:\(pattern)"] = 1
        }
        var features = FileFeatures()
        (features.sparse, features.names) = FeatureVectorizer.vectorize(raw)
        features.kind = .other
        return features
    }

    static func textFile(_ name: String, _ text: String) -> FileFeatures {
        var features = FileFeatures()
        var raw = textRaw(text, extra: ["kind:text": 1, "ext:txt": 1])
        for word in TokenNormalizer.filenameWords(name) {
            if let token = TokenNormalizer.normalize(word) {
                raw["n:\(token)"] = 1
            }
        }
        (features.sparse, features.names) = FeatureVectorizer.vectorize(raw)
        features.kind = .text
        // a different made-up embedding for every name
        let seed = FeatureHash.fnv1a64(name)
        features.dense = (0..<512).map { Float((UInt64($0) &* 2_654_435_761 &+ seed) % 1000) / 1000 - 0.5 }
        return features
    }

    // the dense sum after a relaunch, to 4 decimals
    static func denseDigest(_ data: LearningStore.DestinationData) -> String {
        guard let sum = data.denseSum else { return "none" }
        return String(format: "%016llx", FeatureHash.fnv1a64(sum.map { String(format: "%.4f", $0) }.joined(separator: ",")))
    }

    static func sameDense(_ a: [Float]?, _ b: [Float]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) < 1e-4 }
        default: return false
        }
    }

    static func signature(_ data: LearningStore.DestinationData) -> String {
        let text = (data.examples.map { $0.stored.code.base64EncodedString() + "\($0.weight)" }
                    + data.negatives.map { $0.stored.code.base64EncodedString() + "\($0.value)" })
            .joined(separator: ",")
        return String(format: "%016llx", FeatureHash.fnv1a64(text))
    }

    // pass/fail lines and the exit code
    @MainActor
    final class Checks {
        private(set) var failures: [String] = []

        func expect(_ condition: Bool, _ what: String) {
            print(condition ? "  ok   \(what)" : "  FAIL \(what)")
            if !condition {
                failures.append(what)
            }
        }

        func finish() -> Int32 {
            print(failures.isEmpty ? "\nSELFTEST PASS" : "\nSELFTEST FAIL (\(failures.count))")
            return failures.isEmpty ? 0 : 1
        }
    }
}
#endif
