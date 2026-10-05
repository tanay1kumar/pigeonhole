#if DEBUG
import Foundation

enum EvalTests: TestSuite {
    static let name = "Eval"

    static var tests: [TestCase] {
        [
            TestCase("splitmix64 reference values and shuffles") { t in
                // reference output for seed 1 (the algorithm's published constants)
                var rng = SplitMix64(seed: 1)
                let first = rng.next()
                var again = SplitMix64(seed: 1)
                t.expectEqual(again.next(), first, "same seed, same numbers")
                var zero = SplitMix64(seed: 0)
                t.expectEqual(zero.next(), 0xE220A8397B1DCDAF, "known first value for seed 0")
                var a = SplitMix64(seed: 7)
                var b = SplitMix64(seed: 7)
                let items = Array(0..<20)
                let shuffledA = a.shuffled(items)
                t.expectEqual(shuffledA, b.shuffled(items))
                t.expectEqual(shuffledA.sorted(), items, "a permutation")
                t.expect(shuffledA != items, "actually shuffled")
                var c = SplitMix64(seed: 8)
                t.expect(c.shuffled(items) != shuffledA, "another seed, another order")
                var single = SplitMix64(seed: 3)
                t.expectEqual(single.shuffled([42]), [42])
                t.expectEqual(single.shuffled([Int]()), [])
            },
            TestCase("layout: sorted, controls apart, hidden and nested ignored") { t in
                let root = try t.tempDirectory()
                for folder in ["Receipts", "Flowers", "_none", ".hidden"] {
                    try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
                }
                try Data("x".utf8).write(to: root.appendingPathComponent("Flowers/b.txt"))
                try Data("x".utf8).write(to: root.appendingPathComponent("Flowers/a.txt"))
                try Data("x".utf8).write(to: root.appendingPathComponent("Flowers/.DS_Store"))
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Flowers/nested"), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: root.appendingPathComponent("Flowers/nested/c.txt"))
                try Data("x".utf8).write(to: root.appendingPathComponent("Receipts/r.txt"))
                try Data("x".utf8).write(to: root.appendingPathComponent("_none/song.mp3"))
                try Data("x".utf8).write(to: root.appendingPathComponent("loose.txt"))
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Receipts/link.txt"),
                                                           withDestinationURL: root.appendingPathComponent("loose.txt"))
                guard let layout = Eval.scan(root) else {
                    t.fail("scan failed")
                    return
                }
                t.expectEqual(layout.destinations, ["Flowers", "Receipts"])
                t.expectEqual(layout.controls, ["_none"])
                t.expectEqual(layout.files.map { "\($0.folder)/\($0.url.lastPathComponent)" },
                              ["Flowers/a.txt", "Flowers/b.txt", "Receipts/loose.txt", "Receipts/r.txt", "_none/song.mp3"])
                t.expect(Eval.scan(root.appendingPathComponent("missing")) == nil)
            },
            TestCase("params file overrides only what it names") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("params.json")
                try Data(#"{"alpha": 3, "confidentFloor": 0.2, "labelCap": 10, "blockWeights": {"n": 0.9}}"#.utf8).write(to: url)
                guard let params = Eval.loadParams(url, into: ScoringParams()) else {
                    t.fail("didn't load")
                    return
                }
                t.expectEqual(params.alpha, 3)
                t.expectEqual(params.confidentFloor, 0.2)
                t.expectEqual(params.labelCap, 10)
                t.expectEqual(params.blockWeights["n"], 0.9)
                t.expectEqual(params.blockWeights["c"], 1.0, "untouched weights keep their default")
                t.expectEqual(params.beta, ScoringParams().beta)
                try Data("not json".utf8).write(to: url)
                t.expect(Eval.loadParams(url, into: ScoringParams()) == nil)
            },
            TestCase("rates and percentiles") { t in
                t.expectEqual(Eval.rate(1, 4), "25.0% (1/4)")
                t.expectEqual(Eval.rate(0, 0), "n/a (0/0)")
                t.expectEqual(Eval.percentile([1, 2, 3, 4], 0.5), 2)
                t.expectEqual(Eval.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95), 10)
                t.expectEqual(Eval.percentile([], 0.5), 0)
                t.expectEqual(Eval.macroAccuracy([(1, 2), (2, 2), (0, 0)]), 0.75, "empty folders don't count")
            },
            TestCase("a small eval runs end to end and repeats exactly") { t in
                let root = try t.tempDirectory()
                let folders: [(String, [(String, String)])] = [
                    ("Receipts", [("a.txt", "total tax subtotal paid visa store 12.50"), ("b.txt", "receipt total paid cashier 4.99 tax"),
                                  ("c.txt", "subtotal tax total thank you visa 7.25")]),
                    ("School", [("d.txt", "lecture homework assignment exam syllabus"), ("e.txt", "midterm quiz lecture notes professor"),
                                ("f.txt", "homework problem set solution due friday")]),
                    ("_none", [("g.txt", "weekend hike ramen grandma bike")]),
                ]
                for (folder, files) in folders {
                    try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
                    for (name, text) in files {
                        try Data(text.utf8).write(to: root.appendingPathComponent("\(folder)/\(name)"))
                    }
                }
                var options = Eval.Options(directory: root)
                options.runs = 3
                options.jsonURL = root.appendingPathComponent("a.json")
                t.expectEqual(await Eval.run(options), 0)
                options.jsonURL = root.appendingPathComponent("b.json")
                t.expectEqual(await Eval.run(options), 0)
                let a = try Data(contentsOf: root.appendingPathComponent("a.json"))
                let b = try Data(contentsOf: root.appendingPathComponent("b.json"))
                t.expectEqual(a, b, "same seed, same results")
                let json = try JSONSerialization.jsonObject(with: a) as? [String: Any]
                let zero = json?["zeroShot"] as? [String: Any]
                t.expectEqual(zero?["micro"] as? Double, 1, "these texts are easy")
                t.expectEqual(zero?["controlsConfident"] as? Int, 0)
                let one = json?["oneFolder"] as? [String: Any]
                t.expect(one?["k1"] != nil && one?["k3"] != nil, "the one-folder section is in the json (and so in the repeat check)")
            },
            TestCase("unreadable files stop the eval with exit 2") { t in
                let root = try t.tempDirectory()
                try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
                let locked = root.appendingPathComponent("A/locked.txt")
                try Data("x".utf8).write(to: locked)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
                t.expectEqual(await Eval.run(Eval.Options(directory: root)), 2)
                t.expectEqual(await Eval.run(Eval.Options(directory: root.appendingPathComponent("nope"))), 2)
            },
        ]
    }
}
#endif
