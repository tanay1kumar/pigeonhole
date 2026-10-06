#if DEBUG
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// makes real files for the extraction tests
enum TestFiles {
    static let receiptText = "TRADER JOE'S #552\n123 MAIN ST\n\nBANANAS        0.99\nOAT MILK       3.49\nCOFFEE BEANS   8.99\n\nSUBTOTAL      13.47\nTAX            1.08\nTOTAL        $14.55\n\nVISA ****1234\nTHANK YOU"

    static func renderText(_ text: String, width: Int, height: Int, fontSize: CGFloat, gray: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(in: CGRect(x: 40, y: 40, width: width - 80, height: height - 80),
                                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                                 .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType = .png, embedThumbnail: Bool = false) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if embedThumbnail {
            properties[kCGImageDestinationEmbedThumbnail] = true
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // a pdf with real text on one page
    static func writeTextPDF(_ text: String, to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(in: box.insetBy(dx: 50, dy: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }

    // a pdf page that is only a picture, like a scan
    static func writeImagePDF(_ image: CGImage, to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    static func writeRichText(_ text: String, to url: URL, type: NSAttributedString.DocumentType) throws {
        let string = NSAttributedString(string: text)
        let data = try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: [.documentType: type])
        try data.write(to: url)
    }

    static func setXattrPlist(_ value: Any, name: String, on url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, data.count, 0, 0)
        }
        if result != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static var sunflower: URL {
        URL(fileURLWithPath: "/Library/User Pictures/Flowers/Sunflower.heic").resolvingSymlinksInPath()
    }
}

enum FeatureVectorTests: TestSuite {
    static let name = "Vectorizer"

    static var tests: [TestCase] {
        [
            TestCase("fnv-1a test vectors") { t in
                t.expectEqual(FeatureHash.fnv1a64(""), 0xcbf29ce484222325)
                t.expectEqual(FeatureHash.fnv1a64("a"), 0xaf63dc4c8601ec8c)
                t.expectEqual(FeatureHash.index("c:flower"), 877239)
                t.expectEqual(FeatureHash.index("n:resume"), 378438)
                t.expect(FeatureHash.index("anything at all") < 1 << 20)
            },
            TestCase("token normalization") { t in
                let nfd = "re\u{0301}sume\u{0301}"
                let nfc = "résumé"
                t.expectEqual(TokenNormalizer.normalize(nfd), "resume")
                t.expectEqual(TokenNormalizer.normalize(nfc), "resume")
                t.expectEqual(TokenNormalizer.normalize("RÉSUMÉS"), "resume")
                t.expectEqual(TokenNormalizer.normalize("Flowers"), "flower")
                t.expectEqual(TokenNormalizer.normalize("receipts"), "receipt")
                t.expectEqual(TokenNormalizer.normalize("glass"), "glass")
                t.expectEqual(TokenNormalizer.normalize("bus"), "bus")
                t.expectEqual(TokenNormalizer.normalize("cats"), "cat")
                t.expectEqual(TokenNormalizer.normalize("naïve"), "naive")
                t.expectEqual(TokenNormalizer.normalize("the"), nil)
                t.expectEqual(TokenNormalizer.normalize("The"), nil)
                t.expectEqual(TokenNormalizer.normalize("x"), nil)
                t.expectEqual(TokenNormalizer.normalize(""), nil)
                t.expectEqual(TokenNormalizer.normalize("2024"), nil)
                t.expectEqual(TokenNormalizer.normalize("14.55"), nil, "prices aren't words")
                t.expectEqual(TokenNormalizer.normalize("1,234"), nil)
                t.expectEqual(TokenNormalizer.normalize("3/15"), nil)
                t.expectEqual(TokenNormalizer.normalize("v2"), "v2")
                t.expectEqual(TokenNormalizer.normalize("2024", keepDigits: true), "2024")
                t.expectEqual(TokenNormalizer.normalize("1099", keepDigits: true), "1099")
                t.expectEqual(TokenNormalizer.normalize("cs101"), "cs101")
                t.expectEqual(TokenNormalizer.normalize(String(repeating: "a", count: 30)), String(repeating: "a", count: 30))
                t.expectEqual(TokenNormalizer.normalize(String(repeating: "a", count: 31)), nil)
            },
            TestCase("filename words") { t in
                t.expectEqual(TokenNormalizer.filenameWords("TanayKumarResume_2025-v2.pdf"), ["Tanay", "Kumar", "Resume", "2025", "v2", "v"])
                t.expectEqual(TokenNormalizer.filenameWords("IMG_2041.HEIC"), ["IMG", "2041"])
                t.expectEqual(TokenNormalizer.filenameWords("HTMLParser.swift"), ["HTML", "Parser"])
                t.expectEqual(TokenNormalizer.filenameWords("lecture07_recursion.pdf"), ["lecture07", "lecture", "recursion"])
                t.expectEqual(TokenNormalizer.filenameWords("Screenshot 2026-10-05 at 02.10.00.png"), ["Screenshot", "2026", "10", "05", "at", "02", "10", "00"])
                t.expectEqual(TokenNormalizer.filenameWords("doc_final2.pdf"), ["doc", "final2", "final"])
                // plural acronyms stay whole, course codes keep their digits and their letters
                t.expectEqual(TokenNormalizer.filenameWords("Tanay CVs.pdf"), ["Tanay", "CVs"])
                t.expectEqual(TokenNormalizer.filenameWords("IDs scan.jpg"), ["IDs", "scan"])
                t.expectEqual(TokenNormalizer.filenameWords("PDFs.zip"), ["PDFs"])
                t.expectEqual(TokenNormalizer.filenameWords("CS101_notes.pdf"), ["CS101", "CS", "notes"])
                t.expectEqual(TokenNormalizer.filenameWords("W2_2024.pdf"), ["W2", "W", "2024"])
                t.expectEqual(TokenNormalizer.filenameWords("MATH2210 hw3.pdf"), ["MATH2210", "MATH", "hw3", "hw"])
                t.expectEqual(TokenNormalizer.filenameWords("ReceiptScan.jpg"), ["Receipt", "Scan"])
                t.expectEqual(TokenNormalizer.normalize("CVs"), "cvs")
                // names are split the same way, without an extension to drop
                t.expectEqual(TokenNormalizer.words("CS101 Notes v1.2"), ["CS101", "CS", "Notes", "v1", "v", "2"])
                t.expectEqual(TokenNormalizer.words("MathHomework"), ["Math", "Homework"])
                t.expectEqual(TokenNormalizer.normalize("CS101", keepDigits: true), "cs101")
                t.expectEqual(TokenNormalizer.filenameWords("résumé.docx"), ["résumé"])
                t.expectEqual(TokenNormalizer.filenameWords(""), [])
                t.expectEqual(TokenNormalizer.filenameWords("___.txt"), [])
                t.expectEqual(TokenNormalizer.filenameWords("archive.tar.gz"), ["archive", "tar"])
            },
            TestCase("vectorizer: unit length, block weights, sorted indices") { t in
                let (vector, names) = FeatureVectorizer.vectorize(["c:invoice": 1, "c:total": 1, "size:lt100k": 1, "kind:pdf": 1])
                t.expect(abs(vector.norm - 1) < 1e-5, "norm \(vector.norm)")
                t.expectEqual(vector.indices, vector.indices.sorted())
                t.expectEqual(Set(vector.indices).count, vector.indices.count)
                t.expectEqual(names.count, 4)
                func value(_ name: String) -> Float {
                    let index = FeatureHash.index(name)
                    return vector.values[vector.indices.firstIndex(of: index)!]
                }
                // 2 c features -> 0.707 each times c's weight, size and kind one each
                let weights = BlockWeights.standard
                t.expect(abs(value("c:invoice") / value("size:lt100k") - 0.7071 * weights["c"]! / weights["size"]!) < 0.01)
                t.expect(abs(value("kind:pdf") / value("size:lt100k") - weights["kind"]! / weights["size"]!) < 0.01)
                t.expect(abs(value("c:invoice") - value("c:total")) < 1e-6)
                t.expectEqual(names[FeatureHash.index("c:invoice")], "c:invoice")
            },
            TestCase("vectorizer: values inside a block keep their ratios") { t in
                let (vector, _) = FeatureVectorizer.vectorize(["v:flower": 0.9, "v:plant": 0.3])
                let flower = vector.values[vector.indices.firstIndex(of: FeatureHash.index("v:flower"))!]
                let plant = vector.values[vector.indices.firstIndex(of: FeatureHash.index("v:plant"))!]
                t.expect(abs(flower / plant - 3) < 1e-4)
                t.expect(abs(vector.norm - 1) < 1e-5)
            },
            TestCase("vectorizer: empty, zero and bad input") { t in
                t.expect(FeatureVectorizer.vectorize([:]).vector.isEmpty)
                t.expect(FeatureVectorizer.vectorize(["c:x": 0]).vector.isEmpty)
                t.expect(FeatureVectorizer.vectorize(["c:x": .nan, "c:y": -1]).vector.isEmpty)
                t.expectEqual(BlockWeights.standard["nope"], nil)
                for namespace in ["c", "v", "flag", "n", "src", "name", "pat", "kind", "ext", "from", "size"] {
                    t.expect(BlockWeights.standard[namespace] != nil, namespace)
                }
                t.expectEqual(FeatureVectorizer.namespace(of: "c:x"), "c")
                t.expectEqual(FeatureVectorizer.namespace(of: "nocolon"), nil)
                t.expectEqual(FeatureVectorizer.namespace(of: ":x"), nil)
            },
            TestCase("vectorizer is deterministic") { t in
                var raw: [String: Float] = [:]
                for i in 0..<300 {
                    raw["c:word\(i)"] = Float(i % 7 + 1) / 3
                }
                raw["v:flower"] = 0.52
                raw["n:resume"] = 1
                let a = FeatureVectorizer.vectorize(raw)
                let b = FeatureVectorizer.vectorize(Dictionary(uniqueKeysWithValues: raw.map { ($0.key, $0.value) }.reversed()))
                t.expectEqual(a.vector, b.vector)
            },
            TestCase("tokens with stray marks and possessives") { t in
                t.expectEqual(FeatureVectorizer.namespace(of: "c:\u{301}ecole"), "c", "combining mark right after the colon")
                t.expectEqual(TokenNormalizer.normalize("\u{301}Ecole"), "ecole")
                t.expectEqual(TokenNormalizer.normalize("\u{200B}\u{301}"), nil)
                t.expectEqual(TokenNormalizer.normalize("Bachelor's"), "bachelor")
                t.expectEqual(TokenNormalizer.normalize("Master’s"), "master")
                t.expectEqual(TokenNormalizer.normalize("'quoted'"), "quoted")
                t.expectEqual(TokenNormalizer.normalize("it's"), nil, "a stopword once the 's goes")
                let (vector, _) = FeatureVectorizer.vectorize(["c:\u{301}m": 1, "c:ok": 1])
                t.expectEqual(vector.indices.count, 2, "no feature dropped or trapped")
            },
            TestCase("sparse vector math") { t in
                let a = SparseVector(pairs: [(5, 1), (1, 2), (5, 1)])
                t.expectEqual(a.indices, [1, 5])
                t.expectEqual(a.values, [2, 2])
                let b = SparseVector(indices: [1, 3], values: [1, 1])
                t.expectEqual(a.dot(b), 2)
                t.expect(abs(a.cosine(b) - 2 / (Float(8).squareRoot() * Float(2).squareRoot())) < 1e-6)
                let sum = a.adding(b, scale: -1)
                t.expectEqual(sum.indices, [1, 3, 5])
                t.expectEqual(sum.values, [1, -1, 2])
                t.expect(abs(a.normalized().norm - 1) < 1e-6)
                t.expectEqual(SparseVector().normalized(), SparseVector())
                t.expectEqual(SparseVector().cosine(a), 0)
            },
        ]
    }
}

enum FilePatternTests: TestSuite {
    static let name = "Patterns"

    static var tests: [TestCase] {
        [
            TestCase("filename patterns") { t in
                let cases: [(String, [String])] = [
                    ("IMG_1234.jpg", ["camera"]),
                    ("PXL_20250101_123.jpg", ["camera"]),
                    ("img_1234.jpg", []),
                    ("Screenshot 2026-10-05 at 02.10.00.png", ["date", "screenshot"]),
                    ("Screen Shot 2019-01-01 at 1.00.00 PM.png", ["date", "screenshot"]),
                    ("Screen Recording 2026-10-05 at 10.00.00.mov", ["date", "screenrecording"]),
                    ("scan_0912.png", ["scan"]),
                    ("Scanned Document.pdf", ["scan"]),
                    ("scanner_manual.pdf", []),
                    ("Copy of report.docx", ["copy"]),
                    ("copyright.txt", []),
                    ("doc_final2.pdf", ["version"]),
                    ("essay_v3.docx", ["version"]),
                    ("draft notes.txt", ["version"]),
                    ("finale.mp3", []),
                    ("2024_03_15 receipt.pdf", ["date"]),
                    // camelCase counts as separate words
                    ("ResumeFinal.pdf", ["version"]),
                    ("EssayDraft.docx", ["version"]),
                    ("ReportV2.pdf", ["version"]),
                    ("ReportCopy.docx", ["copy"]),
                    ("ReceiptScan.jpg", ["scan"]),
                    ("ScreenRecording 2026-10-05.mov", ["date", "screenrecording"]),
                ]
                for (filename, expected) in cases {
                    t.expectEqual(FilePatterns.namePatterns(filename).sorted(), expected.sorted(), filename)
                }
            },
            TestCase("content patterns") { t in
                t.expect(FilePatterns.contentPatterns(TestFiles.receiptText).contains("money"))
                t.expect(FilePatterns.contentPatterns("TOTAL\n...\n$14.55").contains("money"), "label and amount on separate lines")
                t.expect(!FilePatterns.contentPatterns("14.55 apples and pears").contains("money"))
                for text in ["Amount due: $1,250.00", "TOTAL $2,500.00", "Total 1.234,56 EUR", "1,234.56 total", "Subtotal $12,345.67"] {
                    t.expect(FilePatterns.contentPatterns(text).contains("money"), text)
                }
                t.expect(!FilePatterns.contentPatterns("total 14.5").contains("money"))
                t.expect(!FilePatterns.contentPatterns("total of 1,234 people").contains("money"))
                t.expect(!FilePatterns.contentPatterns("version 1.234.56 total").contains("money"))
                t.expect(FilePatterns.contentPatterns("Form W-2 Wage and Tax Statement").contains("taxform"))
                t.expect(FilePatterns.contentPatterns("1099-INT").contains("taxform"))
                t.expect(FilePatterns.contentPatterns("Form 1040").contains("taxform"))
                t.expect(!FilePatterns.contentPatterns("w2w2 10999").contains("taxform"))
                t.expect(FilePatterns.contentPatterns("due 2024-03-15").contains("date"))
                t.expect(FilePatterns.contentPatterns("on 3/15/2024").contains("date"))
                t.expect(FilePatterns.contentPatterns("March 15, 2024").contains("date"))
                t.expect(FilePatterns.contentPatterns("mail me: jane.doe+cv@example.co.uk").contains("email"))
                t.expect(FilePatterns.contentPatterns("call (555) 123-4567").contains("phone"))
                t.expect(FilePatterns.contentPatterns("call 555-123-4567").contains("phone"))
                t.expect(FilePatterns.contentPatterns("+1 555 123 4567").contains("phone"))
                t.expectEqual(FilePatterns.contentPatterns("hello world"), [])
            },
            TestCase("patterns stay fast on long unbroken text") { t in
                let dna = String(repeating: "ACGT", count: 4096)
                let hex = String(repeating: "deadbeef", count: 2048)
                for text in [dna, hex, ">chr1 sample\n" + dna] {
                    let started = Date()
                    _ = FilePatterns.contentPatterns(text)
                    t.expect(Date().timeIntervalSince(started) < 0.2, "took \(Date().timeIntervalSince(started)) s")
                }
                t.expect(FilePatterns.contentPatterns("write to <a@b.org> now").contains("email"))
                t.expect(FilePatterns.contentPatterns("x@y.com").contains("email"))
                let tags = String(repeating: "if (a < b) { c = d < e; }\n", count: 600)
                let started = Date()
                _ = FilePatterns.stripHTML(tags)
                t.expect(Date().timeIntervalSince(started) < 0.2, "tag stripping is linear")
            },
            TestCase("size buckets") { t in
                t.expectEqual(FilePatterns.sizeBucket(0), "lt100k")
                t.expectEqual(FilePatterns.sizeBucket(99_999), "lt100k")
                t.expectEqual(FilePatterns.sizeBucket(100_000), "lt1m")
                t.expectEqual(FilePatterns.sizeBucket(9_999_999), "lt10m")
                t.expectEqual(FilePatterns.sizeBucket(10_000_000), "lt100m")
                t.expectEqual(FilePatterns.sizeBucket(100_000_000), "ge100m")
            },
            TestCase("origin folder token") { t in
                t.expectEqual(FilePatterns.originToken("Downloads"), "downloads")
                t.expectEqual(FilePatterns.originToken("05_Résumés Documents"), "05_resumes_documents")
                t.expectEqual(FilePatterns.originToken("..."), nil)
                t.expectEqual(FilePatterns.originToken(""), nil)
            },
            TestCase("html stripping") { t in
                let text = FilePatterns.stripHTML("<html><head><style>p{color:red}</style><script>var x=1</script></head><body><p>Invoice &amp; receipt</p></body></html>")
                t.expect(text.contains("Invoice & receipt"), text)
                t.expect(!text.contains("color") && !text.contains("var x"), text)
                // a script the 16 KB read cut off, and comments
                let cut = FilePatterns.stripHTML("<p>Order receipt</p><!-- tracking pixel --><script>window.dataLayer.push(gtag config")
                t.expect(cut.contains("Order receipt") && !cut.contains("dataLayer") && !cut.contains("tracking"), cut)
            },
            TestCase("download source domains") { t in
                t.expectEqual(SpotlightInfo.sourceFeatures("https://www.amazon.com/gp/css/summary"), ["amazon.com", "amazon"])
                t.expectEqual(SpotlightInfo.sourceFeatures("https://docs.google.com/document/d/x"), ["google.com", "google"])
                t.expectEqual(SpotlightInfo.sourceFeatures("https://www.bbc.co.uk/news"), ["bbc.co.uk", "bbc"])
                t.expectEqual(SpotlightInfo.sourceFeatures("https://lh3.googleusercontent.com/abc"), [])
                t.expectEqual(SpotlightInfo.sourceFeatures("https://d111.cloudfront.net/f.pdf"), [])
                t.expectEqual(SpotlightInfo.sourceFeatures("https://bucket.s3.amazonaws.com/f.pdf"), [])
                t.expectEqual(SpotlightInfo.sourceFeatures("not a url"), [])
                t.expectEqual(SpotlightInfo.sourceFeatures("http://localhost:8080/x"), [])
                t.expectEqual(SpotlightInfo.sourceFeatures("https://uwaterloo.ca/x"), ["uwaterloo.ca", "uwaterloo"])
                t.expectEqual(SpotlightInfo.sourceFeatures("http://192.168.1.10/file.pdf"), [])
                t.expectEqual(SpotlightInfo.sourceFeatures("http://10.0.0.5:8000/a"), [])
                t.expectEqual(SpotlightInfo.sourceFeatures("http://[::1]/x"), [])
            },
            TestCase("spotlight xattr fallbacks") { t in
                let dir = try t.tempDirectory()
                let shot = dir.appendingPathComponent("plain.png")
                TestFiles.writeImage(TestFiles.renderText("hello", width: 200, height: 100, fontSize: 20), to: shot)
                t.expect(!SpotlightInfo.isScreenshot(shot))
                try TestFiles.setXattrPlist(true, name: "com.apple.metadata:kMDItemIsScreenCapture", on: shot)
                t.expect(SpotlightInfo.isScreenshot(shot))

                let download = dir.appendingPathComponent("invoice.pdf")
                try Data("x".utf8).write(to: download)
                try TestFiles.setXattrPlist(["https://www.amazon.com/orders/1", "https://cdn.cloudfront.net/x", "https://www.paypal.com/x"],
                                            name: "com.apple.metadata:kMDItemWhereFroms", on: download)
                t.expectEqual(SpotlightInfo.whereFroms(download).count, 3)
                // only the first two urls count, cdns are skipped
                t.expectEqual(SpotlightInfo.downloadSources(of: download), ["amazon.com", "amazon"])
                t.expectEqual(SpotlightInfo.downloadSources(of: shot), [])
            },
        ]
    }
}

enum FeatureExtractorTests: TestSuite {
    static let name = "Extractor"

    static func kindOf(_ name: String, in dir: URL, directory: Bool = false) throws -> FileKind {
        let url = dir.appendingPathComponent(name)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("x".utf8).write(to: url)
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey])
        return FileKind.detect(url, values: values)
    }

    static func one(_ url: URL, _ options: ExtractOptions = ExtractOptions()) async -> FileFeatures {
        await FeatureExtractor().extract([url], options: options, useCache: false)[0]
    }

    static func has(_ features: FileFeatures, _ name: String) -> Bool {
        features.sparse.indices.contains(FeatureHash.index(name))
    }

    static var tests: [TestCase] {
        [
            TestCase("file kinds, first match wins") { t in
                let dir = try t.tempDirectory()
                let cases: [(String, FileKind, Bool)] = [
                    ("a.docx", .richText, false), ("a.doc", .richText, false), ("a.rtf", .richText, false), ("a.odt", .richText, false),
                    ("a.pdf", .pdf, false), ("a.heic", .image, false), ("a.png", .image, false), ("a.svg", .image, false),
                    ("a.swift", .code, false), ("a.py", .code, false), ("a.ts", .code, false), ("a.ipynb", .code, false),
                    ("a.pptx", .presentation, false), ("a.xlsx", .spreadsheet, false), ("a.csv", .text, false),
                    ("a.mp3", .audio, false), ("a.m4a", .audio, false), ("a.mov", .movie, false), ("a.mp4", .movie, false),
                    ("a.zip", .archive, false), ("a.json", .text, false), ("a.md", .text, false), ("a.html", .text, false),
                    ("a.txt", .text, false), ("a.zzqxunknown", .other, false), ("noextension", .other, false),
                    ("Folder", .folder, true), ("Some.app", .folder, true),
                ]
                for (name, expected, directory) in cases {
                    t.expectEqual(try kindOf(name, in: dir, directory: directory), expected, name)
                }
            },
            TestCase("flower photo: labels, small thumbnail, no ocr") { t in
                let features = await one(TestFiles.sunflower)
                t.expectEqual(features.kind, .image)
                guard let size = features.classifySize else {
                    t.fail("no classification image")
                    return
                }
                t.expect(max(size.width, size.height) <= 384, "\(size)")
                let labels = features.labels.map(\.0)
                t.expect(labels.contains("sunflower") || labels.contains("flower"), "\(labels)")
                t.expect(has(features, "v:sunflower") || has(features, "v:flower"))
                t.expectEqual(features.ocrReason, nil)
                t.expectEqual(features.ocrSize, nil)
                t.expect(abs(features.sparse.norm - 1) < 1e-4)
                t.expectEqual(features.dense?.count, 512)
                if let dense = features.dense {
                    let norm = dense.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    t.expect(abs(norm - 1) < 1e-3, "dense norm \(norm)")
                }
                t.expect(features.summary.contains("sunflower"), features.summary)
                t.expect(has(features, "kind:image") && has(features, "ext:heic") && has(features, "n:sunflower"))
            },
            TestCase("receipt image: ocr gate opens, money found") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("r1200.png")
                TestFiles.writeImage(TestFiles.renderText(TestFiles.receiptText, width: 1200, height: 1600, fontSize: 40), to: url)
                let features = await one(url)
                t.expect(features.ocrReason != nil, "labels \(features.labels.map(\.0))")
                t.expect(features.textLength > 40, "recognized \(features.textLength) chars")
                t.expect(has(features, "pat:money"), "money pattern")
                t.expect(has(features, "c:total") || has(features, "c:subtotal"), "total word")
                if let size = features.ocrSize {
                    t.expect(max(size.width, size.height) <= 1600, "\(size)")
                }
            },
            TestCase("screenshot and scan hints open the gate on their own") { t in
                // a flower photo has no document label, so only the hint can open the gate
                let dir = try t.tempDirectory()
                let photo = dir.appendingPathComponent("photo.heic")
                try FileManager.default.copyItem(at: TestFiles.sunflower, to: photo)
                try TestFiles.setXattrPlist(true, name: "com.apple.metadata:kMDItemIsScreenCapture", on: photo)
                let flagged = await one(photo)
                t.expect(has(flagged, "flag:screenshot"))
                t.expectEqual(flagged.ocrReason, "flag:screenshot")
                let scan = dir.appendingPathComponent("scan_0912.heic")
                try FileManager.default.copyItem(at: TestFiles.sunflower, to: scan)
                t.expectEqual(await one(scan).ocrReason, "name:scan")
                let shot = dir.appendingPathComponent("Screenshot 2026-10-05 at 02.10.00.heic")
                try FileManager.default.copyItem(at: TestFiles.sunflower, to: shot)
                t.expectEqual(await one(shot).ocrReason, "name:screenshot")
            },
            TestCase("ocr reads a screenshot's words") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("capture.png")
                TestFiles.writeImage(TestFiles.renderText("meeting notes agenda budget timeline review", width: 1400, height: 900, fontSize: 36), to: url)
                try TestFiles.setXattrPlist(true, name: "com.apple.metadata:kMDItemIsScreenCapture", on: url)
                let features = await one(url)
                t.expect(has(features, "flag:screenshot"))
                t.expect(features.ocrReason != nil)
                t.expect(has(features, "c:meeting") || has(features, "c:agenda"), "ocr words")
            },
            TestCase("a symlinked drop is read through the link") { t in
                // the system photos are symlinks into /System
                let features = await one(URL(fileURLWithPath: "/Library/User Pictures/Flowers/Sunflower.heic"))
                t.expectEqual(features.kind, .image)
                t.expect(!features.labels.isEmpty, "classified, not name-only")
            },
            TestCase("the summary carries vision labels, not just the name") { t in
                let dir = try t.tempDirectory()
                let photo = dir.appendingPathComponent("IMG_0001.heic")
                try FileManager.default.copyItem(at: TestFiles.sunflower, to: photo)
                let features = await one(photo)
                t.expect(features.summary.split(separator: " ").contains("flower"), features.summary)
            },
            TestCase("english check: all-caps receipts count, other languages don't") { t in
                let extractor = FeatureExtractor()
                let receipt = "WALMART SUPERCENTER ST# 5260 OP# 00000158 TE# 85 TR# 03960 GV 2% MILK 007874235187 F 2.88 BANANAS 1.26 SUBTOTAL 4.14 TOTAL 4.14 DEBIT TEND 4.14 CHANGE DUE 0.00"
                t.expect(await extractor.isEnglish(receipt), "all-caps english receipt")
                t.expect(await extractor.isEnglish("Dear hiring manager, I am writing to apply for the internship position at your company."))
                t.expect(!(await extractor.isEnglish("Sehr geehrte Damen und Herren, hiermit bewerbe ich mich um die ausgeschriebene Stelle in Ihrem Unternehmen.")))
                t.expect(!(await extractor.isEnglish("Madame, Monsieur, je me permets de vous adresser ma candidature pour le poste de stagiaire.")))
                t.expect(await extractor.isEnglish("short"), "too short to judge")
            },
            TestCase("embedded thumbnails: jpeg redone at 384, heic preview used") { t in
                let dir = try t.tempDirectory()
                let image = TestFiles.renderText("TOTAL $14.55\nTAX 1.08\nVISA ****1234", width: 4032, height: 3024, fontSize: 160, gray: 0.95)
                let jpeg = dir.appendingPathComponent("emb.jpg")
                let heic = dir.appendingPathComponent("emb.heic")
                TestFiles.writeImage(image, to: jpeg, type: .jpeg, embedThumbnail: true)
                TestFiles.writeImage(image, to: heic, type: .heic, embedThumbnail: true)
                let jpegFeatures = await one(jpeg)
                let heicFeatures = await one(heic)
                t.expectEqual(jpegFeatures.classifySize, CGSize(width: 384, height: 288))
                t.expectEqual(heicFeatures.classifySize, CGSize(width: 320, height: 240))
                t.expect(jpegFeatures.ocrReason != nil && heicFeatures.ocrReason != nil,
                         "gate: jpeg \(jpegFeatures.labels.map(\.0)) heic \(heicFeatures.labels.map(\.0))")
                t.expectEqual(jpegFeatures.ocrSize, CGSize(width: 1600, height: 1200))
                t.expectEqual(heicFeatures.ocrSize, CGSize(width: 1600, height: 1200))
            },
            TestCase("--diag-boxes counts boxes for every image, outside the budget") { t in
                var options = ExtractOptions()
                options.diagBoxes = true
                let features = await one(TestFiles.sunflower, options)
                t.expect(features.textBoxes != nil, "boxes counted even with the gate closed")
                t.expectEqual(features.ocrReason, nil)
                t.expectEqual(features.ocrSize, nil, "no ocr ran")
                t.expect(features.diagSize != nil)
                let stages = ["metadata", "thumbnail", "classify", "vectorize"].compactMap { features.timings[$0] }.reduce(0, +)
                t.expect(features.totalMs < stages + 5, "diag work isn't in the total (\(features.totalMs) vs stages \(stages))")
            },
            TestCase("text pdf: words, no ocr") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("resume.pdf")
                TestFiles.writeTextPDF("Work experience: software engineering intern. Education: bachelor of computer science. Skills: Swift, Python.", to: url)
                let features = await one(url)
                t.expectEqual(features.kind, .pdf)
                t.expectEqual(features.ocrReason, nil)
                t.expect(has(features, "c:experience") && has(features, "c:education") && has(features, "c:skill"))
                t.expect(features.dense != nil)
            },
            TestCase("scanned pdf: rendered and read") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("receipt_scan.pdf")
                TestFiles.writeImagePDF(TestFiles.renderText(TestFiles.receiptText, width: 1200, height: 1600, fontSize: 40), to: url)
                let features = await one(url)
                t.expectEqual(features.kind, .pdf)
                t.expectEqual(features.ocrReason, "scanned pdf")
                t.expect(features.textLength > 40)
                t.expect(has(features, "pat:money"))
                if let size = features.ocrSize {
                    t.expect(max(size.width, size.height) <= 1600, "\(size)")
                }
            },
            TestCase("docx and rtf: words") { t in
                let dir = try t.tempDirectory()
                let docx = dir.appendingPathComponent("cv_draft.docx")
                let rtf = dir.appendingPathComponent("letter.rtf")
                try TestFiles.writeRichText("Dear hiring manager, I am applying for the internship position.", to: docx, type: .officeOpenXML)
                try TestFiles.writeRichText("Dear hiring manager, sincerely yours.", to: rtf, type: .rtf)
                let docxFeatures = await one(docx)
                let rtfFeatures = await one(rtf)
                t.expectEqual(docxFeatures.kind, .richText)
                t.expect(has(docxFeatures, "c:internship") && has(docxFeatures, "c:hiring"))
                t.expect(has(rtfFeatures, "c:sincerely"))
            },
            TestCase("plain text, html and code read; notebooks don't") { t in
                let dir = try t.tempDirectory()
                let txt = dir.appendingPathComponent("syllabus.txt")
                try Data("Course syllabus: lectures, homework, midterm exam.".utf8).write(to: txt)
                let html = dir.appendingPathComponent("page.html")
                try Data("<html><body><h1>Invoice</h1><script>tracking()</script></body></html>".utf8).write(to: html)
                let code = dir.appendingPathComponent("main.swift")
                try Data("let invoiceTotal = 42 // compute totals".utf8).write(to: code)
                let notebook = dir.appendingPathComponent("analysis.ipynb")
                try Data("{\"cells\": [\"secret words\"]}".utf8).write(to: notebook)
                let txtFeatures = await one(txt)
                let htmlFeatures = await one(html)
                let codeFeatures = await one(code)
                let notebookFeatures = await one(notebook)
                t.expect(has(txtFeatures, "c:syllabu") || has(txtFeatures, "c:syllabus"), "\(txtFeatures.names.values.sorted())")
                t.expect(has(htmlFeatures, "c:invoice") && !has(htmlFeatures, "c:tracking"))
                t.expectEqual(codeFeatures.kind, .code)
                t.expect(has(codeFeatures, "c:compute"))
                t.expectEqual(notebookFeatures.kind, .code)
                t.expect(!has(notebookFeatures, "c:secret"), "notebooks are name-only")
            },
            TestCase("name-only kinds never read content") { t in
                let dir = try t.tempDirectory()
                let extractor = FeatureExtractor()
                for name in ["song.mp3", "clip.mp4", "files.zip", "deck.pptx"] {
                    let url = dir.appendingPathComponent(name)
                    try Data("x".utf8).write(to: url)
                    let features = await extractor.extract([url], useCache: false)[0]
                    t.expect(features.kind.isNameOnly, name)
                    for stage in ["thumbnail", "classify", "pdfText", "richText", "readText", "ocr"] {
                        t.expect(features.timings[stage] == nil, "\(name) ran \(stage)")
                    }
                    t.expect(has(features, "ext:\((name as NSString).pathExtension)"), name)
                    t.expectEqual(features.ocrReason, nil)
                }
            },
            TestCase("folders are name-only") { t in
                let dir = try t.tempDirectory()
                let folder = dir.appendingPathComponent("Tax Documents 2024")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let features = await one(folder)
                t.expectEqual(features.kind, .folder)
                t.expect(has(features, "kind:folder") && has(features, "n:tax") && has(features, "n:document"))
                t.expect(!features.names.values.contains { $0.hasPrefix("size:") })
            },
            TestCase("text with a stray combining mark extracts (no debug trap)") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("bio.txt")
                try Data("Studied at the \u{301}Ecole Polytechnique, then the Bachelor's program".utf8).write(to: url)
                let features = await one(url)
                t.expect(has(features, "c:ecole") && has(features, "c:bachelor"), "\(features.names.values.sorted())")
            },
            TestCase("text decoding: utf-16, windows-1252, binary, cut utf-8") { t in
                let dir = try t.tempDirectory()
                let utf16 = dir.appendingPathComponent("resume16.txt")
                try ("Experience: internship. Education: bachelor of science.".data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 })!.write(to: utf16)
                t.expect(has(await one(utf16), "c:internship"), "utf-16 with a bom")
                let cp1252 = dir.appendingPathComponent("cv1252.txt")
                try "Résumé and café notes".data(using: .windowsCP1252)!.write(to: cp1252)
                let latin = await one(cp1252)
                t.expect(has(latin, "c:resume") && has(latin, "c:cafe"), "\(latin.names.values.sorted())")
                let binary = dir.appendingPathComponent("blob.txt")
                try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x41, 0x42, 0x43]).write(to: binary)
                t.expect(!(await one(binary)).names.values.contains { $0.hasPrefix("c:") }, "binary has no words")
                // a .ts that is a video
                let video = dir.appendingPathComponent("clip.ts")
                var packets = Data(count: 188 * 4)
                for packet in 0..<4 {
                    packets[packet * 188] = 0x47
                }
                try packets.write(to: video)
                let videoFeatures = await one(video)
                t.expectEqual(videoFeatures.kind, .movie)
                t.expect(has(videoFeatures, "kind:movie") && !has(videoFeatures, "kind:code"))
                // 16 KB that ends halfway through an é
                let long = dir.appendingPathComponent("long.txt")
                var text = Data(String(repeating: "lecture notes ", count: 1170).utf8)
                text = text.prefix(16 * 1024 - 1) + Data([0xC3, 0xA9])
                try text.write(to: long)
                t.expect(has(await one(long), "c:lecture"), "a cut multibyte character doesn't spoil utf-8")
            },
            TestCase("transparent images are read on white") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("scan_transparent.png")
                let width = 1200, height = 1600
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                (TestFiles.receiptText as NSString).draw(in: CGRect(x: 40, y: 40, width: width - 80, height: height - 80),
                                                         withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 40, weight: .regular), .foregroundColor: NSColor.black])
                NSGraphicsContext.restoreGraphicsState()
                TestFiles.writeImage(context.makeImage()!, to: url)
                let features = await one(url)
                t.expect(features.textLength > 40, "ocr found the text (\(features.textLength) chars)")
                t.expect(!features.labels.contains { $0.0 == "night_sky" }, "\(features.labels.map(\.0))")
            },
            TestCase("a password-protected pdf isn't treated as a scan") { t in
                let dir = try t.tempDirectory()
                let plain = dir.appendingPathComponent("plain.pdf")
                TestFiles.writeTextPDF("Confidential salary statement gross pay net pay", to: plain)
                let locked = dir.appendingPathComponent("locked_statement.pdf")
                guard let document = PDFDocument(url: plain),
                      document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]) else {
                    t.fail("couldn't make a locked pdf")
                    return
                }
                let features = await one(locked)
                t.expectEqual(features.kind, .pdf)
                t.expectEqual(features.ocrReason, nil)
                t.expect(features.timings["ocr"] == nil && features.timings["pdfRender"] == nil, "no render, no ocr")
                t.expect(has(features, "n:statement"), "name words still count")
            },
            TestCase("a folder with a dot keeps its words") { t in
                let dir = try t.tempDirectory()
                let folder = dir.appendingPathComponent("2024.Taxes")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let features = await one(folder)
                t.expectEqual(features.kind, .folder)
                t.expect(has(features, "n:taxe"), "\(features.names.values.sorted())")
                t.expect(!features.names.values.contains { $0.hasPrefix("ext:") })
            },
            TestCase("a cancelled extraction isn't joined by the next request") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("receipt.png")
                TestFiles.writeImage(TestFiles.renderText(TestFiles.receiptText, width: 1200, height: 1600, fontSize: 40), to: url)
                let extractor = FeatureExtractor()
                let first = Task { await extractor.extract([url]) }
                try await Task.sleep(for: .milliseconds(5))
                first.cancel()
                // asks for the same file while the cancelled one may still be in flight
                let second = await extractor.extract([url])[0]
                t.expect(!second.cancelled, "the live request got real features")
                t.expect(!second.labels.isEmpty)
                _ = await first.value
            },
            TestCase("unreadable and missing files don't crash") { t in
                let dir = try t.tempDirectory()
                let missing = await one(dir.appendingPathComponent("nope.pdf"))
                t.expect(missing.kind == .pdf || missing.kind == .other)
                let broken = dir.appendingPathComponent("broken.jpg")
                try Data("not a jpeg".utf8).write(to: broken)
                let brokenFeatures = await one(broken)
                t.expectEqual(brokenFeatures.kind, .image)
                t.expectEqual(brokenFeatures.classifySize, nil)
                t.expect(has(brokenFeatures, "kind:image"))
            },
            TestCase("deadline keeps what's there") { t in
                var options = ExtractOptions()
                options.deadline = 0.000_001
                let features = await one(TestFiles.sunflower, options)
                t.expect(features.deadlineHit)
                t.expectEqual(features.dense, nil)
                t.expect(has(features, "kind:image"), "metadata survives")
            },
            TestCase("the deadline is a real timer: a slow stage can't hold the result") { t in
                // a big noisy png takes far longer to decode than the deadline
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("huge.png")
                let side = 5000
                let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                if let pixels = context.data?.assumingMemoryBound(to: UInt32.self) {
                    var seed: UInt32 = 12345
                    for index in 0..<(side * side) {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        pixels[index] = seed | 0xFF00_0000
                    }
                }
                TestFiles.writeImage(context.makeImage()!, to: url)
                var options = ExtractOptions()
                options.deadline = 0.02
                let started = Date()
                let features = await FeatureExtractor().extract([url], options: options, useCache: false)[0]
                let elapsed = Date().timeIntervalSince(started)
                t.expect(features.deadlineHit)
                t.expect(elapsed < 0.4, "returned after \(elapsed) s")
                t.expect(has(features, "kind:image") && has(features, "ext:png"), "metadata from the snapshot")
                t.expect(features.labels.isEmpty, "classification hadn't run yet")
            },
            TestCase("ocr is skipped when the deadline is too close, labels kept") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("r1200.png")
                TestFiles.writeImage(TestFiles.renderText(TestFiles.receiptText, width: 1200, height: 1600, fontSize: 40), to: url)
                var options = ExtractOptions()
                options.deadline = 0.45
                let features = await FeatureExtractor().extract([url], options: options, useCache: false)[0]
                t.expect(features.ocrReason?.hasSuffix("(skipped: deadline)") == true, features.ocrReason ?? "nil")
                t.expect(!features.labels.isEmpty, "labels kept")
                t.expectEqual(features.ocrSize, nil)
            },
            TestCase("an unreadable file is an error, not 'nothing to see'") { t in
                let dir = try t.tempDirectory()
                let url = dir.appendingPathComponent("locked.pdf")
                TestFiles.writeTextPDF("Invoice total amount due", to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
                let extractor = FeatureExtractor()
                let locked = await extractor.extract([url])[0]
                t.expect(locked.error != nil)
                t.expectEqual(locked.kind, .pdf)
                t.expect(has(locked, "kind:pdf"), "name and kind still count")
                // readable again, not from the cache
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                let readable = await extractor.extract([url])[0]
                t.expectEqual(readable.error, nil)
                t.expect(has(readable, "c:invoice"))
                t.expectEqual(await extractor.extractions, 2)
            },
            TestCase("cache: hits, size or mtime changes, options, in-flight sharing") { t in
                let dir = try t.tempDirectory()
                let extractor = FeatureExtractor()
                let url = dir.appendingPathComponent("notes.txt")
                try Data("homework assignment".utf8).write(to: url)
                let first = await extractor.extract([url])[0]
                let second = await extractor.extract([url])[0]
                t.expectEqual(await extractor.extractions, 1)
                t.expectEqual(second.timings["cache"], 1)
                t.expectEqual(first.sparse, second.sparse)

                // same mtime, new size (coarse mtime disks), extracted again
                let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
                try Data("homework assignment, now longer".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
                _ = await extractor.extract([url])
                t.expectEqual(await extractor.extractions, 2)

                // same size, new mtime, extracted again
                try Data("homework assignment, now LONGER".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: mtime.addingTimeInterval(10)], ofItemAtPath: url.path)
                _ = await extractor.extract([url])
                t.expectEqual(await extractor.extractions, 3)

                // other options get their own entry so eval's from:eval doesn't leak into the app
                var evalOptions = ExtractOptions()
                evalOptions.origin = "eval"
                let evalFeatures = await extractor.extract([url], options: evalOptions)[0]
                t.expectEqual(await extractor.extractions, 4)
                t.expect(has(evalFeatures, "from:eval"))

                // the same file twice in one drop is extracted once
                let other = dir.appendingPathComponent("other.txt")
                try Data("lecture".utf8).write(to: other)
                _ = await extractor.extract([other, other])
                t.expectEqual(await extractor.extractions, 5)

                // a deadline-hit result isn't kept
                var hurried = ExtractOptions()
                hurried.deadline = 0.000_001
                let quick = dir.appendingPathComponent("quick.txt")
                try Data("syllabus".utf8).write(to: quick)
                _ = await extractor.extract([quick], options: hurried)
                _ = await extractor.extract([quick], options: hurried)
                t.expectEqual(await extractor.extractions, 7)
            },
            TestCase("cache: least recently used goes first") { t in
                let dir = try t.tempDirectory()
                let extractor = FeatureExtractor()
                var files: [URL] = []
                for index in 0..<50 {
                    let file = dir.appendingPathComponent("f\(index).txt")
                    try Data("file \(index)".utf8).write(to: file)
                    files.append(file)
                    _ = await extractor.extract([file])
                }
                // touch the oldest then add one more, f1 is now oldest and gets evicted
                _ = await extractor.extract([files[0]])
                let extra = dir.appendingPathComponent("extra.txt")
                try Data("extra".utf8).write(to: extra)
                _ = await extractor.extract([extra])
                t.expectEqual(await extractor.cacheCount, 50)
                let before = await extractor.extractions
                t.expectEqual(await extractor.extract([files[0]])[0].timings["cache"], 1, "touched entry survived")
                t.expectEqual(await extractor.extractions, before)
                _ = await extractor.extract([files[1]])
                t.expectEqual(await extractor.extractions, before + 1, "the least recently used was evicted")
            },
            TestCase("two overlapping drops still extract at most two files at once") { t in
                let dir = try t.tempDirectory()
                var first: [URL] = []
                var second: [URL] = []
                for index in 0..<4 {
                    for (list, prefix) in [(0, "a"), (1, "b")] {
                        let url = dir.appendingPathComponent("\(prefix)\(index).png")
                        TestFiles.writeImage(TestFiles.renderText("receipt total 1.00 \(prefix)\(index)", width: 600, height: 800, fontSize: 30), to: url)
                        if list == 0 { first.append(url) } else { second.append(url) }
                    }
                }
                let extractor = FeatureExtractor()
                let firstDrop = first, secondDrop = second
                async let a = extractor.extract(firstDrop, useCache: false)
                async let b = extractor.extract(secondDrop, useCache: false)
                let results = await (a, b)
                t.expectEqual(results.0.count + results.1.count, 8)
                t.expectEqual(await extractor.maxRunning, 2)
            },
            TestCase("cancelling a drop stops the work") { t in
                let dir = try t.tempDirectory()
                var urls: [URL] = []
                for index in 0..<8 {
                    let url = dir.appendingPathComponent("r\(index).png")
                    TestFiles.writeImage(TestFiles.renderText(TestFiles.receiptText, width: 1200, height: 1600, fontSize: 40), to: url)
                    urls.append(url)
                }
                let extractor = FeatureExtractor()
                let task = Task { await extractor.extract(urls) }
                try await Task.sleep(for: .milliseconds(30))
                task.cancel()
                let results = await task.value
                t.expectEqual(results.count, 8)
                t.expect(results.contains { $0.cancelled }, "some files never ran")
                let extracted = await extractor.extractions
                t.expect(extracted < 8, "\(extracted) extracted")
                // cancelled results aren't cached, a new drop redoes the work
                let again = await extractor.extract([urls[7]])[0]
                t.expect(!again.cancelled && !again.labels.isEmpty)
            },
            TestCase("at most two files at once, results in drop order") { t in
                let dir = try t.tempDirectory()
                var urls: [URL] = []
                let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
                for word in words {
                    let url = dir.appendingPathComponent("\(word).png")
                    TestFiles.writeImage(TestFiles.renderText("receipt total 1.00", width: 600, height: 800, fontSize: 30), to: url)
                    urls.append(url)
                }
                let extractor = FeatureExtractor()
                let results = await extractor.extract(urls, useCache: false)
                t.expectEqual(results.count, 6)
                t.expectEqual(await extractor.maxRunning, 2)
                for (index, features) in results.enumerated() {
                    t.expect(has(features, "n:\(words[index])"), "row \(index) is \(words[index])")
                }
            },
            TestCase("same file, same features") { t in
                let a = await one(TestFiles.sunflower)
                let b = await one(TestFiles.sunflower)
                t.expectEqual(a.sparse, b.sparse)
                t.expectEqual(FeaturesReport.signature(a), FeaturesReport.signature(b))
            },
        ]
    }
}
#endif
