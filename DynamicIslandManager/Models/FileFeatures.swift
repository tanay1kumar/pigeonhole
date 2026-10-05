import Foundation
import CoreGraphics
import UniformTypeIdentifiers

// first match wins (the plan §4.2); the raw value is the kind: feature token
enum FileKind: String, CaseIterable {
    case folder, richText, pdf, image, code, presentation, spreadsheet, audio, movie, archive, text, other

    static let richTextExtensions: Set<String> = ["docx", "doc", "odt", "rtf"]

    // the plan §4.2 order; values needs isDirectory, isPackage and contentType
    static func detect(_ url: URL, values: URLResourceValues?) -> FileKind {
        if values?.isDirectory == true || values?.isPackage == true {
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        if richTextExtensions.contains(ext) {
            return .richText
        }
        guard let type = values?.contentType ?? UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        // uttype calls .ts an mpeg-2 transport stream
        if type.conforms(to: .sourceCode) || ext == "ipynb" || ext == "ts" { return .code }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .movie }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .text) || type.conforms(to: .plainText) { return .text }
        return .other
    }

    // folders, media and archives are classified on name and metadata alone
    var isNameOnly: Bool {
        switch self {
        case .folder, .presentation, .spreadsheet, .audio, .movie, .archive, .other: return true
        default: return false
        }
    }
}

// everything the classifier knows about one dropped file
struct FileFeatures {
    var sparse = SparseVector()              // unit length
    var dense: [Float]?                      // unit length sentence embedding, english only
    var names: [UInt32: String] = [:]        // index -> "ns:token" for this file only, never persisted
    var raw: [String: Float] = [:]           // before vectorizing, so eval can try other block weights
    var kind: FileKind = .other
    var timings: [String: Double] = [:]      // ms per stage
    var ocrReason: String?

    // diagnostics for --features and the eval report
    var classifySize: CGSize?
    var ocrSize: CGSize?
    var textBoxes: Int?                      // --diag-boxes only
    var diagSize: CGSize?                    // --diag-boxes: the 1600 px image it counted on
    var labels: [(String, Float)] = []       // vision labels kept
    var summary = ""                         // what the sentence embedding saw
    var textLength = 0                       // characters of content text read or recognized
    var deadlineHit = false
    var cancelled = false                    // nobody wanted it anymore; never cached
    var error: String?                       // the content couldn't be read; never cached
    var languageSample = ""                  // start of the text, for the english check

    var totalMs: Double {
        timings["total"] ?? timings.values.reduce(0, +)
    }

    // name for an index, for why-text and printing
    func name(of index: UInt32) -> String? {
        names[index]
    }
}
