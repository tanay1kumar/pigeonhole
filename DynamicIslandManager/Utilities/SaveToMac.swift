import AppKit

// save to mac puts a converted file next to its original, with finder style names
@MainActor
enum SaveToMac {
    #if DEBUG
    // tests and scenarios answer the save panel, nobody is there to click it
    static var panelAnswer: ((URL) -> URL?)?
    #endif

    // "photo.jpg", then "photo 2.jpg", "photo 3.jpg"
    nonisolated static func destination(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    // next to the original, or where the save panel says when that folder can't be written
    // nil when the panel was cancelled
    static func save(_ converted: URL, nextTo original: URL) async -> URL? {
        let folder = original.deletingLastPathComponent()
        do {
            // on another volume it's a byte copy, not a clone, so off main
            return try await Task.detached {
                let target = SaveToMac.destination(in: folder, name: converted.lastPathComponent)
                try FileManager.default.copyItem(at: converted, to: target)
                return target
            }.value
        } catch {
            print("save to mac: couldn't write next to \(original.lastPathComponent), asking where: \(error.localizedDescription)")
        }
        guard let chosen = askWhere(converted) else { return nil }
        do {
            return try await Task.detached {
                // the panel already asked about replacing it
                if FileManager.default.fileExists(atPath: chosen.path) {
                    try FileManager.default.removeItem(at: chosen)
                }
                try FileManager.default.copyItem(at: converted, to: chosen)
                return chosen
            }.value
        } catch {
            print("save to mac: couldn't write \(chosen.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private static func askWhere(_ converted: URL) -> URL? {
        #if DEBUG
        if let panelAnswer {
            return panelAnswer(converted)
        }
        #endif
        let panel = NSSavePanel()
        panel.nameFieldStringValue = converted.lastPathComponent
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
