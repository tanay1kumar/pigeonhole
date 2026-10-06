#if DEBUG
import Foundation

enum KeywordPackTests: TestSuite {
    static let name = "Packs"

    static func packs(_ name: String, hint: String = "") -> [String] {
        func words(_ text: String) -> [String] {
            TokenNormalizer.words(text).compactMap { TokenNormalizer.normalize($0, keepDigits: true) }
        }
        let fromName = KeywordPacks.matches(words: words(name), name: name).map(\.name)
        let fromHint = KeywordPacks.matches(words: words(hint), name: "").map(\.name)
        var all = fromName
        for pack in fromHint where !all.contains(pack) {
            all.append(pack)
        }
        return all
    }

    static var tests: [TestCase] {
        [
            TestCase("26 starter packs, every trigger normalizes") { t in
                t.expectEqual(KeywordPacks.all.count, 26)
                t.expectEqual(Set(KeywordPacks.all.map(\.name)).count, 26)
                let triggerCount = KeywordPacks.all.reduce(0) { $0 + $1.triggers.count }
                t.expectEqual(KeywordPacks.normalizedTriggers.count, triggerCount)
                for pack in KeywordPacks.all {
                    for extra in pack.extras {
                        let namespace = FeatureVectorizer.namespace(of: extra)
                        t.expect(namespace.flatMap { BlockWeights.standard[$0] } != nil, "\(pack.name): \(extra)")
                    }
                }
            },
            TestCase("names and hints match packs") { t in
                t.expectEqual(packs("Resumes"), ["resumes"])
                t.expectEqual(packs("CV"), ["resumes"])
                t.expectEqual(packs("CVs"), ["resumes"])
                t.expectEqual(packs("Résumés"), ["resumes"])
                t.expectEqual(packs("Cover Letters"), ["cover letters"])
                t.expectEqual(packs("Receipts & Invoices"), ["receipts", "invoices and bills"])
                t.expectEqual(packs("Tax/Bank"), ["taxes", "bank"])
                t.expectEqual(packs("CS 101"), ["school"])
                t.expectEqual(packs("math2210"), ["school"])
                t.expectEqual(packs("Camera Roll"), ["photos"])
                t.expectEqual(packs("Lab Results"), ["medical"])
                t.expectEqual(packs("W2 forms"), ["taxes"])
                t.expectEqual(packs("Misc"), [])
                t.expectEqual(packs("Flowers"), [])
                t.expectEqual(packs("Box B", hint: "resumes CVs cover letters"), ["resumes", "cover letters"])
                t.expectEqual(packs("Job Applications"), ["resumes"])
            },
            TestCase("course codes, not years") { t in
                for name in ["CS-101", "CS_101", "CS.101", "MATH-2210", "BIO 2210L", "ECON 1101", "cs101", "MATH 1920", "ECON 2030"] {
                    t.expectEqual(packs(name), ["school"], name)
                }
                for name in ["Bali 2024", "Mom 2020", "FY 2024", "Work 2024", "Kids 2022", "Rome 2019"] {
                    t.expectEqual(packs(name), [], name)
                }
                t.expect(!packs("Trip 2024").contains("school"), "Trip 2024: \(packs("Trip 2024"))")
                t.expectEqual(packs("Tax 2023"), ["taxes"])
                t.expectEqual(packs("TAX 2023"), ["taxes"], "a capitalized word that's already a pack is still a year")
            },
        ]
    }
}

enum ClassifierTests: TestSuite {
    static let name = "Classifier"

    static func destination(_ name: String, hint: String? = nil) -> Destination {
        Destination(id: "t:\(name)", name: name, path: name, hint: hint)
    }

    static func features(_ raw: [String: Float], kind: FileKind = .other, dense: [Float]? = nil) -> FileFeatures {
        var features = FileFeatures()
        (features.sparse, features.names) = FeatureVectorizer.vectorize(raw)
        features.kind = kind
        features.dense = dense
        return features
    }

    static var tests: [TestCase] {
        [
            TestCase("profiles: flowers, receipts, resumes, misc") { t in
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                let flowers = await classifier.profileFor(destination("Flowers"))
                let labels = Set(flowers.visionLabels.map(\.0))
                for wanted in ["flower", "lily", "rose", "dahlia", "daisy", "tulip", "sunflower", "dandelion"] {
                    t.expect(labels.contains(wanted), "Flowers -> \(wanted)")
                }
                t.expectEqual(flowers.visionLabels.first?.0, "flower")
                t.expectEqual(flowers.visionLabels.first?.1, 1)
                t.expect(flowers.visionLabels.count <= 25)
                let receipts = await classifier.profileFor(destination("Receipts"))
                t.expectEqual(receipts.visionLabels.map(\.0), ["receipt"])
                t.expectEqual(receipts.packs, ["receipts"])
                let resumes = await classifier.profileFor(destination("Resumes"))
                t.expect(resumes.visionLabels.isEmpty)
                t.expectEqual(resumes.packs, ["resumes"])
                t.expect(resumes.dense != nil)
                let misc = await classifier.profileFor(destination("Misc"))
                t.expect(misc.vector.isEmpty && misc.packs.isEmpty && misc.visionLabels.isEmpty)
                let pets = await classifier.profileFor(destination("Pets"))
                let petLabels = Set(pets.visionLabels.map(\.0))
                t.expect(petLabels.contains("cat") && petLabels.contains("dog"), "\(petLabels.sorted())")
                if let adultCat = pets.visionLabels.first(where: { $0.0 == "adult_cat" }) {
                    t.expect(adultCat.1 <= 0.5, "last-word matches get half weight")
                }
            },
            TestCase("profiles: hints add words, generic words are skipped") { t in
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                let boxB = await classifier.profileFor(destination("Box B", hint: "resumes CVs cover letters"))
                t.expectEqual(boxB.packs, ["resumes", "cover letters"])
                t.expect(boxB.names.values.contains("c:experience"))
                let stuff = await classifier.profileFor(destination("My Stuff Folder"))
                t.expect(stuff.vector.isEmpty, "\(stuff.names.values.sorted())")
                let course = await classifier.profileFor(destination("CS 101"))
                t.expectEqual(course.packs, ["school"])
                t.expect(course.names.values.contains("n:101"), "digits kept for folder names")
                let joined = await classifier.profileFor(destination("CS101"))
                t.expect(joined.names.values.contains("n:cs101") && joined.names.values.contains("n:cs"), "\(joined.names.values.sorted())")
                let camel = await classifier.profileFor(destination("MathHomework"))
                t.expect(camel.names.values.contains("n:homework") && camel.packs.contains("school"), "\(camel.packs)")
            },
            TestCase("ranking: the obvious folder wins, misc never confident") { t in
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                let all = [destination("Flowers"), destination("Receipts"), destination("Resumes"), destination("Misc")]
                let sunflower = features(["v:flower": 0.94, "v:plant": 0.94, "v:sunflower": 0.94, "kind:image": 1, "ext:heic": 1], kind: .image)
                let ranking = await classifier.rank(sunflower, among: all)
                t.expectEqual(ranking.items.first?.destination.name, "Flowers")
                t.expectEqual(ranking.level, .confident)
                t.expect(ranking.why.contains("looks like:") && ranking.why.contains("flower"), ranking.why)
                t.expectEqual(ranking.items.count, 4)
                t.expect(abs(ranking.items.reduce(0) { $0 + $1.p } - 1) < 1e-6, "probabilities sum to 1")
                for index in 1..<ranking.items.count {
                    t.expect(ranking.items[index - 1].raw >= ranking.items[index].raw, "sorted")
                }
                let receipt = features(["c:total": 0.7, "c:subtotal": 0.7, "c:tax": 0.7, "c:visa": 0.7, "pat:money": 1, "kind:image": 1], kind: .image)
                let receiptRanking = await classifier.rank(receipt, among: all)
                t.expectEqual(receiptRanking.items.first?.destination.name, "Receipts")
                let unrelated = features(["kind:audio": 1, "ext:mp3": 1, "n:song": 1], kind: .audio)
                let unrelatedRanking = await classifier.rank(unrelated, among: all)
                t.expectEqual(unrelatedRanking.level, .noIdea)
                t.expect(!(unrelatedRanking.items.first?.destination.name == "Misc" && unrelatedRanking.level == .confident))
            },
            TestCase("ranking edge cases: none, one, ties") { t in
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                let file = features(["v:flower": 1, "kind:image": 1], kind: .image)
                let empty = await classifier.rank(file, among: [])
                t.expect(empty.items.isEmpty)
                t.expectEqual(empty.level, .noIdea)
                let single = await classifier.rank(file, among: [destination("Flowers")])
                t.expectEqual(single.items.count, 1)
                t.expectEqual(single.items[0].p, 1)
                t.expectEqual(single.level, .confident, "one destination: raw2 = 0")
                // two empty profiles tie, first in the list wins
                let tie = await classifier.rank(file, among: [destination("Misc"), destination("Stuff")])
                t.expectEqual(tie.items.map(\.destination.name), ["Misc", "Stuff"])
                t.expectEqual(tie.level, .noIdea)
                let tieReversed = await classifier.rank(file, among: [destination("Stuff"), destination("Misc")])
                t.expectEqual(tieReversed.items.map(\.destination.name), ["Stuff", "Misc"])
                // an empty file
                let nothing = await classifier.rank(FileFeatures(), among: [destination("Flowers"), destination("Receipts")])
                t.expectEqual(nothing.level, .noIdea)
            },
            TestCase("levels follow the thresholds") { t in
                let all = [destination("Flowers"), destination("Receipts"), destination("Resumes")]
                let sunflower = features(["v:flower": 0.94, "v:sunflower": 0.94, "kind:image": 1], kind: .image)
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                t.expectEqual(await classifier.rank(sunflower, among: all).level, .confident)
                var strict = ScoringParams()
                strict.confidentFloor = 2
                await classifier.setParams(strict)
                t.expectEqual(await classifier.rank(sunflower, among: all).level, .unsure)
                strict.unsureFloor = 2
                await classifier.setParams(strict)
                t.expectEqual(await classifier.rank(sunflower, among: all).level, .noIdea)
                // the margin alone can hold it back
                var margin = ScoringParams()
                margin.confidentMargin = 2
                await classifier.setParams(margin)
                t.expectEqual(await classifier.rank(sunflower, among: all).level, .unsure)
            },
            TestCase("a dense term below the file's mean lowers the score, never the floor") { t in
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                let all = [destination("Flowers"), destination("Receipts"), destination("Resumes")]
                let raw: [String: Float] = ["v:flower": 0.94, "v:sunflower": 0.94, "kind:image": 1]
                let plain = await classifier.rank(features(raw, kind: .image), among: all)
                let receiptish = await FeatureExtractor().embed("receipt total tax paid store")
                let mixed = await classifier.rank(features(raw, kind: .image, dense: receiptish), among: all)
                t.expectEqual(mixed.items.first?.destination.name, "Flowers")
                t.expect(mixed.items[0].raw < plain.items[0].raw, "the signed dense term counts in the score")
                t.expect(mixed.floor >= plain.floor - 1e-6, "floor \(mixed.floor) vs \(plain.floor)")
            },
            TestCase("one learned photo or resume doesn't make every photo or pdf confident") { t in
                let store = LearningStore(fileURL: nil)
                let classifier = DestinationClassifier(store: store)
                let extractor = FeatureExtractor()
                let all = [destination("Flowers"), destination("Resumes"), destination("Receipts")]
                let photo: [String: Float] = ["kind:image": 1, "ext:heic": 1, "from:downloads": 1, "size:lt100k": 1, "name:camera": 1]
                let sunflower = features(photo.merging(["v:flower": 0.94, "v:plant": 0.94, "v:sunflower": 0.94, "n:sunflower": 1]) { $1 },
                                         kind: .image, dense: await extractor.embed("sunflower flower plant sunflower"))
                await classifier.record([LearningEvent(batchId: UUID(), sparse: sunflower.sparse, dense: sunflower.dense,
                                                       chosenId: "t:Flowers", suggestedId: "t:Flowers", level: .confident, kind: .accepted)])
                for (animal, labels) in [("eagle", ["bird", "animal"]), ("zebra", ["animal", "mammal"]), ("owl", ["bird", "animal"])] {
                    var raw = photo
                    raw["n:\(animal)"] = 1
                    for label in labels + [animal] {
                        raw["v:\(label)"] = 0.9
                    }
                    let file = features(raw, kind: .image, dense: await extractor.embed("\(animal) \(labels.joined(separator: " ")) \(animal)"))
                    let ranking = await classifier.rank(file, among: all)
                    t.expect(ranking.level != .confident, "\(animal): \(ranking.level) floor \(ranking.floor) \(ranking.items.map { ($0.destination.name, $0.raw) })")
                }
                // another flower still is
                let rose = features(photo.merging(["v:flower": 0.9, "v:rose": 0.9, "v:plant": 0.9, "n:rose": 1]) { $1 },
                                    kind: .image, dense: await extractor.embed("rose flower plant rose"))
                t.expectEqual(await classifier.rank(rose, among: all).level, .confident)

                let pdf: [String: Float] = ["kind:pdf": 1, "ext:pdf": 1, "from:downloads": 1, "size:lt100k": 1, "name:version": 1]
                for (index, words) in [["education", "experience", "skill"], ["experience", "internship", "skill"], ["education", "reference", "project"]].enumerated() {
                    var raw = pdf
                    raw["n:resume\(index)"] = 1
                    for word in words {
                        raw["c:\(word)"] = 0.7
                    }
                    let resume = features(raw, kind: .pdf, dense: await extractor.embed(words.joined(separator: " ")))
                    await classifier.record([LearningEvent(batchId: UUID(), sparse: resume.sparse, dense: resume.dense,
                                                           chosenId: "t:Resumes", suggestedId: "t:Resumes", level: .confident, kind: .accepted)])
                }
                let lecture = features(pdf.merging(["n:lecture": 1, "c:lecture": 0.7, "c:recursion": 0.7, "c:chapter": 0.7, "c:exam": 0.7]) { $1 },
                                       kind: .pdf, dense: await extractor.embed("lecture recursion chapter exam"))
                let ranking = await classifier.rank(lecture, among: all)
                t.expect(ranking.level != .confident, "lecture: \(ranking.level) floor \(ranking.floor) \(ranking.items.map { ($0.destination.name, $0.raw) })")
            },
            TestCase("what counts as evidence for the levels") { t in
                let file = features(["kind:pdf": 1, "ext:pdf": 1, "ext:blend": 1, "from:downloads": 1, "size:lt100k": 1,
                                     "name:version": 1, "name:screenshot": 1, "pat:email": 1, "pat:phone": 1, "pat:date": 1,
                                     "pat:money": 1, "pat:taxform": 1, "c:invoice": 1, "n:resume": 1, "v:receipt": 1, "src:amazon": 1,
                                     "flag:screenshot": 1], kind: .pdf)
                let flags = DestinationClassifier.contentFlags(file)
                var counted: [String] = []
                for (index, flag) in zip(file.sparse.indices, flags) where flag {
                    counted.append(file.names[index]!)
                }
                t.expectEqual(counted.sorted(), ["c:invoice", "ext:blend", "flag:screenshot", "n:resume", "name:screenshot",
                                                 "pat:money", "pat:taxform", "src:amazon", "v:receipt"])
            },
            TestCase("an unusual file type is evidence on its own") { t in
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                let all = [destination("Flowers"), destination("Receipts"), destination("Stuff")]
                let batch = UUID()
                await classifier.record(["castle", "forest", "city"].map {
                    LearningEvent(batchId: batch, sparse: features(["kind:other": 1, "ext:blend": 1, "n:\($0)": 1]).sparse, dense: nil,
                                  chosenId: "t:Stuff", suggestedId: nil, level: .noIdea, kind: .pickedAtNoIdea)
                })
                // nothing in common but .blend
                let ranking = await classifier.rank(features(["kind:other": 1, "ext:blend": 1, "n:harbor": 1]), among: all)
                t.expectEqual(ranking.items.first?.destination.name, "Stuff")
                t.expect(ranking.level != .noIdea, "\(ranking.level) floor \(ranking.floor)")
                t.expectEqual(ranking.why, ".blend file")
            },
            TestCase("the kNN term and learned dense sums count, by the formula") { t in
                let store = LearningStore(fileURL: nil)
                let classifier = DestinationClassifier(store: store)
                let x = features(["n:alpha": 1, "n:beta": 1, "n:gamma": 1, "ext:blend": 1])
                // one example, centroid and knn are both cos(x, e) so raw = (1 + 0.5 * 1/4) * cos
                let first = features(["n:alpha": 1, "n:beta": 1, "ext:blend": 1])
                await classifier.record([LearningEvent(batchId: UUID(), sparse: first.sparse, dense: nil, chosenId: "t:Stuff",
                                                       suggestedId: nil, level: .noIdea, kind: .pickedAtNoIdea)])
                let one = await classifier.rank(x, among: [destination("Stuff")])
                let params = ScoringParams()
                let cosine = x.sparse.cosine(LearningStore.storedForm(first.sparse))
                let oneExpected = (1 + params.lambdaKScale / 4) * cosine
                t.expect(abs(one.items[0].raw - Double(oneExpected)) < 1e-4, "\(one.items[0].raw) vs \(oneExpected)")
                // four examples at different distances, centroid + lambdaK(4) * mean of top 3
                let more: [[String: Float]] = [["n:alpha": 1, "n:beta": 1, "n:gamma": 1, "ext:blend": 1], ["n:alpha": 1, "ext:blend": 1], ["n:delta": 1, "ext:blend": 1]]
                for raw in more {
                    await classifier.record([LearningEvent(batchId: UUID(), sparse: features(raw).sparse, dense: nil, chosenId: "t:Stuff",
                                                           suggestedId: nil, level: .noIdea, kind: .pickedAtNoIdea)])
                }
                let examples = store.data(for: "t:Stuff")!.examples.map(\.vector)
                t.expectEqual(examples.count, 4)
                var sum = SparseVector()
                for example in examples {
                    sum = sum.adding(example, scale: 1)
                }
                let cent = x.sparse.dot(DestinationClassifier.clampedUnit(sum)) / x.sparse.norm
                let top3 = examples.map { x.sparse.cosine($0) }.sorted(by: >).prefix(3)
                let expected = cent + params.lambdaKScale * 4 / 7 * top3.reduce(0, +) / 3
                let four = await classifier.rank(x, among: [destination("Stuff")])
                t.expect(abs(four.items[0].raw - Double(expected)) < 1e-4, "\(four.items[0].raw) vs \(expected)")

                // dense only, three related texts into Stuff then a file with no sparse overlap
                let extractor = FeatureExtractor()
                let music = ["guitar chords song lyrics", "band rehearsal setlist songs", "drum practice rhythm music"]
                let other = LearningStore(fileURL: nil)
                let classifier2 = DestinationClassifier(store: other)
                for (index, text) in music.enumerated() {
                    await classifier2.record([LearningEvent(batchId: UUID(), sparse: features(["n:m\(index)": 1]).sparse,
                                                            dense: await extractor.embed(text), chosenId: "t:Stuff",
                                                            suggestedId: nil, level: .noIdea, kind: .pickedAtNoIdea)])
                }
                let destinations = [destination("Stuff"), destination("Flowers"), destination("Receipts")]
                let query = await extractor.embed("piano melody sheet music")!
                let file = features(["kind:other": 1], dense: query)
                let ranking = await classifier2.rank(file, among: destinations)
                t.expectEqual(ranking.items.first?.destination.name, "Stuff", "\(ranking.items.map { ($0.destination.name, $0.raw) })")
                // by hand, lambdaE * (cos(e, alpha * q + S) - mean over destinations)
                var cosines: [String: Float] = [:]
                for destination in destinations {
                    var target = await classifier2.profileFor(destination).dense.map { $0.map { $0 * params.alpha } }
                    if let sum = other.data(for: destination.id)?.denseSum {
                        target = target.map { DestinationClassifier.add($0, sum) } ?? sum
                    }
                    if let target {
                        cosines[destination.name] = DestinationClassifier.cosine(query, target)
                    }
                }
                let mean = cosines.values.reduce(0, +) / Float(cosines.count)
                let stuffRaw = ranking.items.first { $0.destination.name == "Stuff" }!.raw
                let denseExpected = params.lambdaE * (cosines["Stuff"]! - mean)
                t.expect(abs(stuffRaw - Double(denseExpected)) < 1e-4, "\(stuffRaw) vs \(denseExpected)")
            },
            TestCase("negatives pull a folder down, but never below an empty one") { t in
                let store = LearningStore(fileURL: nil)
                let classifier = DestinationClassifier(store: store)
                func scene(_ name: String) -> FileFeatures {
                    features(["kind:other": 1, "ext:blend": 1, "n:\(name)": 1, "n:scene": 1])
                }
                let all = [destination("Flowers"), destination("Stuff"), destination("Misc")]
                await classifier.record(["castle", "forest", "city"].map {
                    LearningEvent(batchId: UUID(), sparse: scene($0).sparse, dense: nil, chosenId: "t:Stuff", suggestedId: nil, level: .noIdea, kind: .pickedAtNoIdea)
                })
                let harbor = scene("harbor")
                let before = await classifier.rank(harbor, among: all).items.first { $0.destination.name == "Stuff" }!.raw
                // harbor scene sent elsewhere instead, Stuff learns it was wrong
                await classifier.record([LearningEvent(batchId: UUID(), sparse: harbor.sparse, dense: nil, chosenId: "t:Elsewhere",
                                                       suggestedId: "t:Stuff", level: .confident, kind: .corrected)])
                let after = await classifier.rank(harbor, among: all).items.first { $0.destination.name == "Stuff" }!.raw
                t.expect(after < before, "\(after) < \(before)")

                // a folder with only this file's negative scores 0, not below an empty one
                let lonely = LearningStore(fileURL: nil)
                let classifier2 = DestinationClassifier(store: lonely)
                await classifier2.record([LearningEvent(batchId: UUID(), sparse: harbor.sparse, dense: nil, chosenId: "t:Elsewhere",
                                                        suggestedId: "t:Stuff", level: .confident, kind: .corrected)])
                let ranking = await classifier2.rank(harbor, among: [destination("Stuff"), destination("Misc")])
                t.expectEqual(ranking.items.map(\.destination.name), ["Stuff", "Misc"], "a tie, in list order")
                t.expectEqual(ranking.items[0].raw, 0)
            },
            TestCase("the dense term is centered per file") { t in
                let classifier = DestinationClassifier(store: LearningStore(fileURL: nil))
                let all = [destination("Flowers"), destination("Receipts"), destination("Resumes"), destination("Misc")]
                let extractor = FeatureExtractor()
                // name only file, the only signal is a receipts dense vector
                let file = features(["kind:other": 1], dense: await extractor.embed("receipt total tax paid store"))
                let ranking = await classifier.rank(file, among: all)
                t.expectEqual(ranking.items.first?.destination.name, "Receipts", "\(ranking.items.map { ($0.destination.name, $0.raw) })")
                t.expect(ranking.level != .confident, "dense alone shouldn't be confident")
            },
            TestCase("learning: 3 examples make an empty folder win") { t in
                let store = LearningStore(fileURL: nil)
                let classifier = DestinationClassifier(store: store)
                let all = [destination("Flowers"), destination("Receipts"), destination("Stuff")]
                func scene(_ name: String) -> FileFeatures {
                    features(["kind:other": 1, "ext:blend": 1, "n:\(name)": 1, "n:scene": 1])
                }
                let batch = UUID()
                await classifier.record(["castle", "forest", "city"].map {
                    LearningEvent(batchId: batch, sparse: scene($0).sparse, dense: nil, chosenId: "t:Stuff", suggestedId: nil, level: .noIdea, kind: .pickedAtNoIdea)
                })
                let ranking = await classifier.rank(scene("harbor"), among: all)
                t.expectEqual(ranking.items.first?.destination.name, "Stuff")
                t.expect(ranking.level != .noIdea)
                t.expectEqual(store.data(for: "t:Stuff")?.examples.count, 3)
                t.expectEqual(store.data(for: "t:Stuff")?.stats.accepted, 3)
            },
            TestCase("why text fallbacks") { t in
                let file = features(["kind:pdf": 1], kind: .pdf)
                let empty = SparseVector()
                t.expectEqual(DestinationClassifier.whyText(features: file, centroid: empty, cent: 0, knnPart: 0.3), "like files you sent here")
                t.expectEqual(DestinationClassifier.whyText(features: file, centroid: empty, cent: 0, knnPart: 0), "PDF")
                let resume = features(["c:education": 1, "c:skill": 1, "c:experience": 1, "kind:pdf": 1], kind: .pdf)
                let centroid = FeatureVectorizer.vectorize(["c:education": 1, "c:skill": 1, "c:experience": 1]).vector
                let why = DestinationClassifier.whyText(features: resume, centroid: centroid, cent: 0.8, knnPart: 0)
                t.expect(why.hasPrefix("mentions: "), why)
                t.expect(why.contains("education") && why.contains("skill"), why)
                let source = features(["src:amazon.com": 1, "src:amazon": 1, "kind:pdf": 1], kind: .pdf)
                let sourceCentroid = FeatureVectorizer.vectorize(["src:amazon.com": 1, "src:amazon": 1]).vector
                t.expectEqual(DestinationClassifier.whyText(features: source, centroid: sourceCentroid, cent: 0.5, knnPart: 0), "from amazon.com")
                // a kind with no name says nothing
                let blob = features(["kind:other": 1], kind: .other)
                t.expectEqual(DestinationClassifier.whyText(features: blob, centroid: empty, cent: 0, knnPart: 0), "")
            },
            TestCase("why text: real words and phrases, not tokens") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("course_info.txt")
                try Data("The syllabus lists responsibilities. Syllabus, diagnosis, analysis: see the syllabus.".utf8).write(to: url)
                let file = await FeatureExtractor().extract([url], useCache: false)[0]
                let centroid = FeatureVectorizer.vectorize(["c:syllabu": 1, "c:responsibilitie": 1, "c:diagnosi": 1]).vector
                let why = DestinationClassifier.whyText(features: file, centroid: centroid, cent: 0.8, knnPart: 0)
                t.expect(why.hasPrefix("mentions: syllabus"), why)
                t.expect(why.contains("responsibilities") && why.contains("diagnosis"), why)
                // patterns become phrases, source folder and size never show
                let draft = features(["name:version": 1, "pat:taxform": 1, "pat:email": 1, "from:downloads": 3, "size:lt100k": 3, "kind:pdf": 1], kind: .pdf)
                let draftCentroid = FeatureVectorizer.vectorize(["name:version": 1, "pat:taxform": 1, "pat:email": 1, "from:downloads": 3, "size:lt100k": 3]).vector
                let phrases = DestinationClassifier.whyText(features: draft, centroid: draftCentroid, cent: 0.8, knnPart: 0)
                t.expect(phrases.contains("draft or version in name") && phrases.contains("tax form") && phrases.contains("email address"), phrases)
                t.expect(!phrases.contains("download") && !phrases.contains("lt100k"), phrases)
            },
        ]
    }
}

enum LearningStoreTests: TestSuite {
    static let name = "LearningStore"

    static func vector(_ seed: Int, count: Int = 30) -> SparseVector {
        var pairs: [(UInt32, Float)] = []
        for index in 0..<count {
            pairs.append((UInt32((seed * 7919 + index * 104_729) % (1 << 20)), Float(index % 5 + 1)))
        }
        return SparseVector(pairs: pairs).normalized()
    }

    static func event(_ batch: UUID, _ seed: Int, to chosen: String, suggested: String? = nil,
                      kind: LearningEvent.Kind = .accepted, level: Level = .confident, dense: [Float]? = nil) -> LearningEvent {
        LearningEvent(batchId: batch, sparse: vector(seed), dense: dense, chosenId: chosen, suggestedId: suggested, level: level, kind: kind)
    }

    @MainActor
    static func tempFile(_ t: TestContext) throws -> URL {
        try t.tempDirectory().appendingPathComponent("learning.json")
    }

    static var tests: [TestCase] {
        [
            TestCase("encoding: top 100, 12-bit, unit length, sorted") { t in
                var pairs: [(UInt32, Float)] = []
                for index in 0..<150 {
                    pairs.append((UInt32(index * 6007 % (1 << 20)), Float(150 - index)))
                }
                let original = SparseVector(pairs: pairs).normalized()
                let data = LearningStore.encode(original)
                t.expectEqual(data.count, 400, "100 words of 4 bytes")
                let decoded = LearningStore.decode(data)
                t.expectEqual(decoded.indices.count, 100)
                t.expectEqual(decoded.indices, decoded.indices.sorted())
                t.expect(abs(decoded.norm - 1) < 1e-5)
                // kept the biggest values
                let biggest = Set(zip(original.indices, original.values).sorted { $0.1 > $1.1 }.prefix(100).map(\.0))
                t.expectEqual(Set(decoded.indices), biggest)
                t.expect(decoded.cosine(original) > 0.97, "close to the original")
                // saved bytes decode the same every time and survive save/load
                let stored = LearningStore.StoredVector(original)
                t.expectEqual(stored.code, data)
                t.expectEqual(LearningStore.StoredVector(code: stored.code), stored)
                t.expect(LearningStore.decode(Data()).isEmpty)
                t.expect(LearningStore.decode(Data([1, 2, 3])).isEmpty, "a short tail is ignored")
            },
            TestCase("weights per action, negatives on corrections") { t in
                let store = LearningStore(fileURL: nil)
                let batch = UUID()
                store.record([
                    event(batch, 1, to: "A"),
                    event(batch, 2, to: "B", suggested: "A", kind: .corrected, level: .unsure),
                    event(batch, 3, to: "C", kind: .pickedAtNoIdea, level: .noIdea),
                    event(batch, 4, to: "D", kind: .sendAllUntouched, level: .confident),
                    event(batch, 5, to: "D", kind: .sendAllUntouched, level: .unsure),
                    event(batch, 6, to: "E", suggested: "E", kind: .corrected),
                    event(batch, 7, to: "F", suggested: nil, kind: .corrected),
                ])
                t.expectEqual(store.data(for: "A")?.examples.map(\.weight), [1])
                t.expectEqual(store.data(for: "B")?.examples.map(\.weight), [2])
                t.expectEqual(store.data(for: "A")?.negatives.map(\.value), [0.5])
                t.expectEqual(store.data(for: "C")?.examples.map(\.weight), [1])
                t.expectEqual(store.data(for: "D")?.examples.map(\.weight), [1, 0.5])
                t.expectEqual(store.data(for: "E")?.negatives.count ?? 0, 0, "no negative when suggested == chosen")
                t.expectEqual(store.data(for: "F")?.negatives.count ?? 0, 0)
                t.expectEqual(store.data(for: "B")?.stats.corrected, 1)
                t.expectEqual(store.data(for: "A")?.stats.accepted, 1)
            },
            TestCase("caps drop the oldest") { t in
                let store = LearningStore(fileURL: nil)
                for index in 0..<105 {
                    store.record([event(UUID(), index, to: "A")])
                }
                for index in 0..<55 {
                    store.record([event(UUID(), 1000 + index, to: "B", suggested: "A", kind: .corrected)])
                }
                let a = store.data(for: "A")
                t.expectEqual(a?.examples.count, 100)
                t.expectEqual(a?.negatives.count, 50)
                t.expectEqual(a?.examples.first?.vector, LearningStore.storedForm(vector(5)), "examples 0-4 dropped")
                t.expectEqual(a?.negatives.first?.vector, LearningStore.storedForm(vector(1005)))
            },
            TestCase("dense sums add up and undo subtracts") { t in
                let store = LearningStore(fileURL: nil)
                let d1: [Float] = [1, 0, 0]
                let d2: [Float] = [0, 1, 0]
                store.record([event(UUID(), 1, to: "A", dense: d1)])
                store.record([event(UUID(), 2, to: "A", suggested: "B", kind: .corrected, dense: d2)])
                t.expectEqual(store.data(for: "A")?.denseSum, [1, 2, 0])
                t.expectEqual(store.data(for: "A")?.denseWeight, 3)
                t.expect(store.undoLastBatch())
                t.expectEqual(store.data(for: "A")?.denseSum, [1, 0, 0])
                t.expectEqual(store.data(for: "A")?.denseWeight, 1)
                t.expectEqual(store.data(for: "B")?.negatives.count ?? 0, 0, "the correction's negative went with it")
                t.expect(!store.undoLastBatch(), "only the last batch")
            },
            TestCase("undo of a 3-file batch: back to before, one negative per file") { t in
                let store = LearningStore(fileURL: nil)
                store.record([event(UUID(), 1, to: "A", dense: [1, 1])])
                let before = store.snapshot()
                let batch = UUID()
                store.record([event(batch, 2, to: "A", dense: [0, 1]), event(batch, 3, to: "B", dense: [1, 0])])
                // a retry of the same batch joins it
                store.record([event(batch, 4, to: "C", dense: [1, 1])])
                t.expect(store.undoLastBatch())
                let after = store.snapshot()
                t.expectEqual(after["A"]?.examples.map(\.vector), before["A"]?.examples.map(\.vector))
                t.expectEqual(after["A"]?.denseSum, before["A"]?.denseSum)
                t.expectEqual(after["B"]?.examples.count ?? 0, 0)
                t.expectEqual(after["C"]?.examples.count ?? 0, 0)
                // one undo negative per file, on the folder that file went to
                t.expectEqual(after["A"]?.negatives.map(\.vector), [LearningStore.storedForm(vector(2))])
                t.expectEqual(after["B"]?.negatives.map(\.vector), [LearningStore.storedForm(vector(3))])
                t.expectEqual(after["C"]?.negatives.map(\.vector), [LearningStore.storedForm(vector(4))])
                t.expectEqual(after["B"]?.stats.undone, 1)
            },
            TestCase("undo at the caps puts back what the batch pushed out") { t in
                let store = LearningStore(fileURL: nil)
                for index in 0..<100 {
                    store.record([event(UUID(), index, to: "A")])
                }
                for index in 0..<50 {
                    store.record([event(UUID(), 1000 + index, to: "B", suggested: "S", kind: .corrected)])
                }
                let before = store.snapshot()
                let batch = UUID()
                // two sends into a full folder and a correction away from a full one
                store.record([event(batch, 2000, to: "A"), event(batch, 2001, to: "A"),
                              event(batch, 2002, to: "C", suggested: "S", kind: .corrected)])
                t.expectEqual(store.data(for: "A")?.examples.first?.vector, LearningStore.storedForm(vector(2)), "0 and 1 pushed out")
                t.expectEqual(store.data(for: "S")?.negatives.first?.vector, LearningStore.storedForm(vector(1001)))
                t.expect(store.undoLastBatch())
                let after = store.snapshot()
                t.expectEqual(after["A"]?.examples.map(\.vector), before["A"]?.examples.map(\.vector), "the same 100 in the same order")
                t.expectEqual(after["S"]?.negatives.map(\.vector), before["S"]?.negatives.map(\.vector), "the same 50")
                t.expectEqual(after["A"]?.negatives.map(\.vector), [vector(2000), vector(2001)].map(LearningStore.storedForm))
                t.expectEqual(after["C"]?.negatives.map(\.vector), [LearningStore.storedForm(vector(2002))])
            },
            TestCase("removing a folder keeps the rest of the pending undo") { t in
                let store = LearningStore(fileURL: nil)
                let batch = UUID()
                store.record([event(batch, 1, to: "A", dense: [1, 0]), event(batch, 2, to: "B", suggested: "Z", kind: .corrected)])
                store.removeData(for: "Z")      // the batch only left a negative there
                store.removeData(for: "Q")      // the batch never touched it
                // a retry of the same batch still joins it
                store.record([event(batch, 3, to: "C")])
                t.expect(store.undoLastBatch())
                for (id, seed) in [("A", 1), ("B", 2), ("C", 3)] {
                    t.expectEqual(store.data(for: id)?.examples.count ?? 0, 0, "\(id) undone")
                    t.expectEqual(store.data(for: id)?.negatives.map(\.vector), [LearningStore.storedForm(vector(seed))], "\(id): its undo negative")
                }
                t.expectEqual(store.data(for: "A")?.denseSum, nil)
                t.expectEqual(store.data(for: "Z"), nil, "the removed folder doesn't come back")
                t.expectEqual(store.data(for: "Q"), nil)
            },
            TestCase("a folder removed and picked again: undo only takes back the new part") { t in
                let store = LearningStore(fileURL: nil)
                let batch = UUID()
                store.record([event(batch, 1, to: "A", dense: [1, 0]), event(batch, 2, to: "B")])
                store.removeData(for: "A")
                // A is added back and the batch's retry sends there
                store.record([event(batch, 3, to: "A", dense: [0, 1])])
                t.expect(store.undoLastBatch())
                let a = store.data(for: "A")
                t.expectEqual(a?.examples.count ?? 0, 0)
                t.expectEqual(a?.denseSum, nil)
                t.expectEqual(a?.stats.undone, 1, "the removed part isn't undone a second time")
                t.expectEqual(a?.negatives.map(\.vector), [LearningStore.storedForm(vector(3))], "a negative only for the file still there")
                t.expectEqual(store.data(for: "B")?.negatives.map(\.vector), [LearningStore.storedForm(vector(2))])
            },
            TestCase("a reopened row sent back to the same folder removes its undo negative") { t in
                let store = LearningStore(fileURL: nil)
                let batch = UUID()
                store.record([event(batch, 1, to: "A")])
                store.undoLastBatch()
                t.expectEqual(store.data(for: "A")?.negatives.count, 1)
                // reopened rows come back as corrected with no suggestion
                store.record([event(UUID(), 1, to: "A", suggested: nil, kind: .corrected)])
                t.expectEqual(store.data(for: "A")?.negatives.count, 0)
                t.expectEqual(store.data(for: "A")?.examples.count, 1)
                // sent elsewhere instead, the undo negative stays
                store.record([event(UUID(), 2, to: "A")])
                store.undoLastBatch()
                store.record([event(UUID(), 2, to: "B", suggested: nil, kind: .corrected)])
                t.expectEqual(store.data(for: "A")?.negatives.count, 1)
            },
            TestCase("persists across instances") { t in
                let url = try tempFile(t)
                let store = LearningStore(fileURL: url)
                store.record([event(UUID(), 1, to: "A", dense: [0.5, 0.5]), event(UUID(), 2, to: "B", suggested: "A", kind: .corrected)])
                store.flush()
                let reread = LearningStore(fileURL: url)
                t.expectEqual(reread.loadNote, "loaded")
                t.expectEqual(reread.data(for: "A")?.examples.map(\.stored), store.data(for: "A")?.examples.map(\.stored))
                t.expectEqual(reread.data(for: "A")?.negatives.map(\.stored), store.data(for: "A")?.negatives.map(\.stored))
                // and a second save/load cycle changes nothing either
                reread.record([event(UUID(), 9, to: "Z")])
                reread.flush()
                let third = LearningStore(fileURL: url)
                t.expectEqual(third.data(for: "A")?.examples.map(\.stored), store.data(for: "A")?.examples.map(\.stored))
                t.expectEqual(reread.data(for: "A")?.denseSum, [0.5, 0.5])
                t.expectEqual(reread.data(for: "B")?.examples.map(\.weight), [2])
                t.expectEqual(reread.data(for: "B")?.stats, store.data(for: "B")?.stats)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                t.expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                t.expectEqual(json?["version"] as? Int, 1)
                t.expectEqual(json?["featureVersion"] as? Int, FeatureVectorizer.featureVersion)
                t.expectEqual(json?["visionRevision"] as? Int, 2)
            },
            TestCase("writes are debounced, flush writes now") { t in
                let url = try tempFile(t)
                let store = LearningStore(fileURL: url)
                store.writeDelay = 0.2
                store.record([event(UUID(), 1, to: "A")])
                t.expect(!FileManager.default.fileExists(atPath: url.path), "not written yet")
                await t.eventually(timeout: 2) { FileManager.default.fileExists(atPath: url.path) }
                store.record([event(UUID(), 2, to: "A")])
                store.flush()
                t.expectEqual(LearningStore(fileURL: url).data(for: "A")?.examples.count, 2)
                // in memory never writes
                let memory = LearningStore(fileURL: nil)
                memory.record([event(UUID(), 1, to: "A")])
                memory.flush()
                t.expectEqual(memory.data(for: "A")?.examples.count, 1)
            },
            TestCase("version mismatches") { t in
                let url = try tempFile(t)
                let store = LearningStore(fileURL: url)
                store.record([event(UUID(), 1, to: "A", dense: [1, 0])])
                store.flush()
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]

                json["embeddingRevision"] = 99
                try JSONSerialization.data(withJSONObject: json).write(to: url)
                let newEmbedding = LearningStore(fileURL: url)
                t.expectEqual(newEmbedding.data(for: "A")?.examples.count, 1, "vectors kept")
                t.expectEqual(newEmbedding.data(for: "A")?.denseSum, nil, "dense dropped")

                json["embeddingRevision"] = LearningStore.currentEmbeddingRevision
                json["featureVersion"] = 999
                try JSONSerialization.data(withJSONObject: json).write(to: url)
                let newFeatures = LearningStore(fileURL: url)
                t.expectEqual(newFeatures.data(for: "A")?.examples.count, 0, "vectors dropped")
                t.expectEqual(newFeatures.data(for: "A")?.stats.accepted, 1, "stats kept")

                json["featureVersion"] = FeatureVectorizer.featureVersion
                json["visionRevision"] = 1
                try JSONSerialization.data(withJSONObject: json).write(to: url)
                t.expectEqual(LearningStore(fileURL: url).data(for: "A")?.examples.count, 0)

                json["version"] = 2
                try JSONSerialization.data(withJSONObject: json).write(to: url)
                t.expect(LearningStore(fileURL: url).snapshot().isEmpty, "unknown file version discarded")

                try Data("{not json".utf8).write(to: url)
                t.expect(LearningStore(fileURL: url).snapshot().isEmpty, "garbage discarded")
            },
            TestCase("remove data, reset, prune") { t in
                let url = try tempFile(t)
                let store = LearningStore(fileURL: url)
                store.record([event(UUID(), 1, to: "A"), event(UUID(), 2, to: "B"), event(UUID(), 3, to: "C")])
                store.removeData(for: "A")
                t.expectEqual(store.data(for: "A"), nil)
                t.expectEqual(LearningStore(fileURL: url).data(for: "A"), nil)
                t.expect(LearningStore(fileURL: url).data(for: "B") != nil)
                store.prune(keeping: ["B"])
                store.flush()
                t.expectEqual(LearningStore(fileURL: url).data(for: "C"), nil)
                store.reset()
                t.expect(store.snapshot().isEmpty)
                t.expect(!FileManager.default.fileExists(atPath: url.path))
                // a pending debounced write shouldn't bring the file back
                store.writeDelay = 0.05
                store.record([event(UUID(), 4, to: "D")])
                store.reset()
                try await Task.sleep(for: .milliseconds(200))
                t.expect(!FileManager.default.fileExists(atPath: url.path))
            },
            TestCase("full caps stay under 1 MB") { t in
                let url = try tempFile(t)
                let store = LearningStore(fileURL: url)
                store.fillToCaps(destinationIds: (1...8).map { "dest\($0)" })
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                t.expect(size > 500_000 && size < 1_000_000, "\(size) bytes")
                let reread = LearningStore(fileURL: url)
                t.expectEqual(reread.data(for: "dest1")?.examples.count, 100)
                t.expectEqual(reread.data(for: "dest8")?.negatives.count, 50)
            },
        ]
    }
}

enum DestinationStoreTests: TestSuite {
    static let name = "Destinations"

    static var tests: [TestCase] {
        [
            TestCase("a folder renamed in drive takes the new name, path and hint follow") { t in
                let store = DestinationStore()
                store.debugUseInMemory([Destination(id: "a", name: "reciepts", path: "My Drive / reciepts", hint: "my receipts"),
                                        Destination(id: "b", name: "resumes", path: "resumes"),
                                        Destination(id: "c", name: "gone", path: "gone")])
                let renamed = await store.refreshNames { id in
                    switch id {
                    case "a": return "receipts"
                    case "b": return "resumes"
                    default: throw DriveError(category: .notFound, status: 404)
                    }
                }
                t.expectEqual(renamed, ["reciepts -> receipts"])
                t.expectEqual(store.destinations.map(\.name), ["receipts", "resumes", "gone"], "a folder drive can't read keeps its name")
                t.expectEqual(store.destinations[0].path, "My Drive / receipts")
                t.expectEqual(store.destinations[0].hint, "my receipts")
                t.expectEqual(store.destinations[0].id, "a")
                // a picked folder's path is just its name
                store.rename(id: "b", to: "CVs")
                t.expectEqual(store.destinations[1].path, "CVs")
            },
            TestCase("old saved destinations without hint still decode") { t in
                let old = #"[{"path":"resumes","name":"resumes","id":"1iizA3"},{"path":"My Drive / reciepts","name":"reciepts","id":"11PBjj"}]"#
                let decoded = try JSONDecoder().decode([Destination].self, from: Data(old.utf8))
                t.expectEqual(decoded.count, 2)
                t.expectEqual(decoded[0].hint, nil)
                let withHint = try JSONEncoder().encode([Destination(id: "x", name: "Box B", path: "Box B", hint: "cvs")])
                t.expectEqual(try JSONDecoder().decode([Destination].self, from: withHint)[0].hint, "cvs")
            },
        ]
    }
}
#endif
