import Foundation

// starter knowledge for common folder names, a name or hint matching a trigger
// gets the pack's seed words (weight 0.6) and extra features (0.5)
struct KeywordPack {
    let name: String
    let triggers: [String]      // words or phrases, matched after normalizeToken
    let seeds: [String]         // content words, phrases get split into words
    let extras: [String]        // ready made features (kind:, ext:, flag:, v:, pat:, name:, size:, n:)

    // pack name plus its seed words, part of the destination's dense prior
    var description: String {
        ([name] + seeds).joined(separator: " ")
    }
}

enum KeywordPacks {
    static let all: [KeywordPack] = [
        KeywordPack(name: "resumes",
                    triggers: ["resume", "résumé", "cv", "cvs", "curriculum vitae", "career", "job", "job applications"],
                    seeds: ["experience", "education", "skills", "employment", "work history", "references", "objective",
                            "summary", "internship", "gpa", "bachelor", "master", "linkedin", "proficient", "responsibilities"],
                    extras: ["kind:pdf", "kind:richText"]),
        KeywordPack(name: "cover letters",
                    triggers: ["cover letter"],
                    seeds: ["dear", "hiring manager", "position", "sincerely", "application", "opportunity", "role"],
                    extras: ["kind:pdf", "kind:richText"]),
        KeywordPack(name: "receipts",
                    triggers: ["receipt", "purchase", "expense", "spending"],
                    seeds: ["total", "subtotal", "tax", "receipt", "paid", "payment", "visa", "mastercard", "amex", "change",
                            "cashier", "store", "order", "qty", "item", "thank"],
                    extras: ["pat:money", "v:receipt", "v:document", "v:printed_page"]),
        KeywordPack(name: "invoices and bills",
                    triggers: ["invoice", "bill", "billing", "utilities"],
                    seeds: ["invoice", "bill", "amount due", "due date", "account number", "statement date", "balance",
                            "billing period", "kwh"],
                    extras: ["pat:money"]),
        KeywordPack(name: "taxes",
                    triggers: ["tax", "taxes", "irs", "w2", "1099", "returns"],
                    seeds: ["irs", "tax return", "form", "federal", "withholding", "deduction", "refund", "ein", "ssn"],
                    extras: ["pat:taxform"]),
        KeywordPack(name: "bank",
                    triggers: ["bank", "banking", "statement", "finance", "financial"],
                    seeds: ["statement", "account", "balance", "deposit", "withdrawal", "transaction", "routing", "checking",
                            "savings", "beginning balance", "ending balance"],
                    extras: []),
        KeywordPack(name: "pay stubs",
                    triggers: ["paystub", "payslip", "payroll", "salary"],
                    seeds: ["gross pay", "net pay", "earnings", "deductions", "ytd", "pay period", "employer"],
                    extras: []),
        KeywordPack(name: "contracts and legal",
                    triggers: ["contract", "legal", "agreement", "lease", "nda"],
                    seeds: ["agreement", "party", "parties", "hereby", "terms", "conditions", "signature", "effective date",
                            "termination", "governing law", "whereas", "lessee", "lessor"],
                    extras: []),
        KeywordPack(name: "school",
                    triggers: ["school", "class", "course", "college", "university", "uni", "homework", "hw", "assignment",
                               "lecture", "notes", "semester", "study"],
                    seeds: ["lecture", "homework", "assignment", "due", "exam", "midterm", "final", "quiz", "syllabus",
                            "professor", "chapter", "problem set", "solution", "theorem", "lab"],
                    extras: ["v:whiteboard", "v:handwriting"]),
        KeywordPack(name: "research papers",
                    triggers: ["papers", "research", "articles", "readings", "thesis"],
                    seeds: ["abstract", "introduction", "related work", "methodology", "results", "conclusion", "references",
                            "et al", "doi", "arxiv", "journal", "figure"],
                    extras: []),
        KeywordPack(name: "screenshots",
                    triggers: ["screenshot", "screen shots", "screencap", "capture"],
                    seeds: [],
                    extras: ["flag:screenshot", "name:screenshot", "v:screenshot", "kind:image"]),
        KeywordPack(name: "photos",
                    triggers: ["photo", "pictures", "pics", "camera", "camera roll", "images"],
                    seeds: [],
                    extras: ["kind:image", "name:camera", "ext:heic", "ext:jpg", "ext:jpeg", "ext:png"]),
        KeywordPack(name: "wallpapers",
                    triggers: ["wallpaper", "backgrounds", "desktop pictures"],
                    seeds: [],
                    extras: ["kind:image", "n:wallpaper", "size:lt10m", "size:lt100m"]),
        KeywordPack(name: "memes",
                    triggers: ["meme", "funny", "reactions"],
                    seeds: [],
                    extras: ["kind:image", "n:meme"]),
        KeywordPack(name: "music and audio",
                    triggers: ["music", "songs", "audio", "podcasts", "recordings", "voice memos"],
                    seeds: [],
                    extras: ["kind:audio", "ext:mp3", "ext:m4a", "ext:wav", "ext:flac", "ext:aac"]),
        KeywordPack(name: "videos",
                    triggers: ["video", "movies", "clips", "screen recordings"],
                    seeds: [],
                    extras: ["kind:movie", "ext:mov", "ext:mp4", "ext:m4v", "name:screenrecording"]),
        KeywordPack(name: "design",
                    triggers: ["design", "assets", "mockups", "figma", "logos", "icons", "ui"],
                    seeds: [],
                    extras: ["ext:psd", "ext:ai", "ext:sketch", "ext:fig", "ext:svg", "n:logo", "n:icon", "n:mockup",
                             "v:illustrations"]),
        KeywordPack(name: "code",
                    triggers: ["code", "projects", "dev", "scripts", "src"],
                    seeds: [],
                    extras: ["kind:code", "ext:py", "ext:js", "ext:ts", "ext:swift", "ext:java", "ext:c", "ext:cpp",
                             "ext:ipynb", "ext:json", "ext:yml"]),
        KeywordPack(name: "travel",
                    triggers: ["travel", "trips", "flights", "tickets", "boarding passes", "itinerary", "bookings", "hotels"],
                    seeds: ["flight", "boarding", "gate", "seat", "departure", "arrival", "itinerary", "reservation",
                            "confirmation", "booking", "hotel", "check", "passenger"],
                    extras: []),
        KeywordPack(name: "IDs",
                    triggers: ["id", "ids", "identity", "passport", "license", "licence"],
                    seeds: ["passport", "driver license", "date of birth", "nationality", "expiry", "id number"],
                    extras: ["v:document"]),
        KeywordPack(name: "medical",
                    triggers: ["medical", "health", "doctor", "prescriptions", "lab results"],
                    seeds: ["patient", "diagnosis", "prescription", "dosage", "physician", "clinic", "hospital", "lab results"],
                    extras: []),
        KeywordPack(name: "insurance",
                    triggers: ["insurance", "policies"],
                    seeds: ["policy", "premium", "coverage", "deductible", "insured", "claim", "beneficiary"],
                    extras: []),
        KeywordPack(name: "slides",
                    triggers: ["slides", "presentations", "decks", "pitch"],
                    seeds: ["agenda"],
                    extras: ["kind:presentation", "ext:key", "ext:pptx", "ext:ppt"]),
        KeywordPack(name: "spreadsheets and data",
                    triggers: ["spreadsheets", "data", "sheets", "budget"],
                    seeds: [],
                    extras: ["kind:spreadsheet", "ext:csv", "ext:tsv", "ext:xlsx", "ext:numbers"]),
        KeywordPack(name: "books and manuals",
                    triggers: ["books", "ebooks", "reading", "manuals", "guides"],
                    seeds: ["chapter", "contents", "isbn", "manual", "instructions", "warranty"],
                    extras: ["ext:epub", "ext:mobi"]),
        KeywordPack(name: "installers",
                    triggers: ["installers", "apps", "software"],
                    seeds: [],
                    extras: ["ext:dmg", "ext:pkg", "ext:zip", "kind:folder"]),
    ]

    // course codes like "cs101", "MATH 2210", "CS-101" mean a school folder
    static let courseCode = try! NSRegularExpression(pattern: #"^([a-z]{2,4}) ?([0-9]{3,4})[a-z]?$"#)

    // "Bali 2024" is a year not a course, years only count as course numbers
    // if the prefix looks like one ("MATH 1920") and nothing else matched
    static func isCourseCode(_ name: String, matchedOther: Bool) -> Bool {
        let spaced = name.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[-_./]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let folded = spaced.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard let match = courseCode.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)),
              let numberRange = Range(match.range(at: 2), in: folded),
              let number = Int(folded[numberRange]) else { return false }
        guard (1990...2039).contains(number) else { return true }
        let prefix = String(spaced.prefix { $0.isLetter })
        return !matchedOther && prefix == prefix.uppercased() && prefix.lowercased() != "fy"
    }

    static var school: KeywordPack {
        all.first { $0.name == "school" }!
    }

    // trigger -> normalized word sequence, built once
    static let normalizedTriggers: [(pack: Int, words: [String])] = {
        var result: [(Int, [String])] = []
        for (index, pack) in all.enumerated() {
            for trigger in pack.triggers {
                let words = trigger.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .compactMap { TokenNormalizer.normalize(String($0), keepDigits: true) }
                if !words.isEmpty {
                    result.append((index, words))
                }
            }
        }
        return result
    }()

    // packs whose trigger shows up in the words, "&", "and" and "/" split parts
    static func matches(words: [String], name: String) -> [KeywordPack] {
        var matched: [Int] = []
        for (pack, trigger) in normalizedTriggers where !matched.contains(pack) {
            if contains(words, phrase: trigger) {
                matched.append(pack)
            }
        }
        let schoolIndex = all.firstIndex { $0.name == "school" }!
        if !matched.contains(schoolIndex), isCourseCode(name, matchedOther: !matched.isEmpty) {
            matched.append(schoolIndex)
        }
        return matched.sorted().map { all[$0] }
    }

    private static func contains(_ words: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where Array(words[start..<start + phrase.count]) == phrase {
            return true
        }
        return false
    }
}
