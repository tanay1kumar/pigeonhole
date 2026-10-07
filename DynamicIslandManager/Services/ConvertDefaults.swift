import Foundation
import UniformTypeIdentifiers

// what a drop pre-selects in the format pill, everything is kept unless settings say otherwise
// the general settings pane writes these, scenario runs read and write their scratch domain
enum ConvertDefaults {
    static let heicKey = "convertHEIC"      // "keep" or "jpeg"
    static let audioKey = "convertAudio"    // "keep" or "m4a", for wav and aiff
    static let movieKey = "convertMOV"      // "keep" or "mp4"

    #if DEBUG
    // tests keep everything, scenarios read their scratch domain, neither sees the user's own settings
    static var override: [String: String]? = CommandLine.arguments.contains("--test") ? [:] : nil
    #endif

    static func value(_ key: String) -> String {
        #if DEBUG
        if let override {
            return override[key] ?? "keep"
        }
        #endif
        return AppDefaults.shared.string(forKey: key) ?? "keep"
    }

    // the pill's starting choice for a file, nil keeps it as it is
    static func format(for file: FileItem, value: (String) -> String = ConvertDefaults.value) -> ConvertFormat? {
        guard !file.isDirectory, let type = UTType(filenameExtension: file.fileExtension) else { return nil }
        let wanted: ConvertFormat?
        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            wanted = value(heicKey) == "jpeg" ? .jpeg : nil
        } else if type.conforms(to: .wav) || type.conforms(to: .aiff) {
            wanted = value(audioKey) == "m4a" ? .m4a : nil
        } else if type.conforms(to: .quickTimeMovie) {
            wanted = value(movieKey) == "mp4" ? .mp4 : nil
        } else {
            wanted = nil
        }
        return wanted.flatMap { ConversionService.outputs(for: file.url).contains($0) ? $0 : nil }
    }
}
