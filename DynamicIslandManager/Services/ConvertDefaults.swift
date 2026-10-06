import Foundation
import UniformTypeIdentifiers

// what a drop pre-selects in the format pill, everything is kept unless settings say otherwise
// the general settings pane writes these in the real app, scenarios pass them on the command line
enum ConvertDefaults {
    static let heicKey = "convertHEIC"      // "keep" or "jpeg"
    static let audioKey = "convertAudio"    // "keep" or "m4a", for wav and aiff
    static let movieKey = "convertMOV"      // "keep" or "mp4"

    #if DEBUG
    // --convert-defaults heic=jpeg,audio=m4a,mov=mp4, nothing gets written
    // scenario and test runs keep everything otherwise, the user's own settings never change their checks
    static var override: [String: String]? = {
        if let given = parse(CommandLine.arguments) {
            return given
        }
        return DebugScenarios.isScenarioRun || CommandLine.arguments.contains("--test") ? [:] : nil
    }()

    static func parse(_ arguments: [String]) -> [String: String]? {
        guard let index = arguments.firstIndex(of: "--convert-defaults"), index + 1 < arguments.count else { return nil }
        var values: [String: String] = [:]
        for pair in arguments[index + 1].split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "heic": values[heicKey] = parts[1]
            case "audio": values[audioKey] = parts[1]
            case "mov": values[movieKey] = parts[1]
            default: break
            }
        }
        return values
    }
    #endif

    static func value(_ key: String) -> String {
        #if DEBUG
        if let override {
            return override[key] ?? "keep"
        }
        #endif
        return UserDefaults.standard.string(forKey: key) ?? "keep"
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
