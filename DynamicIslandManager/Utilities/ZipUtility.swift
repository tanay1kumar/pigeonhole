import Foundation

enum ZipError: LocalizedError {
    case creationFailed
    case noFilesToZip
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "Failed to create zip archive"
        case .noFilesToZip:
            return "No files provided to zip"
        case .invalidPath:
            return "Invalid file path"
        }
    }
}

// blocks while ditto runs, call it off the main thread
class ZipUtility {
    static func zipFiles(_ files: [FileItem]) throws -> URL {
        guard !files.isEmpty else {
            throw ZipError.noFilesToZip
        }

        // create temp dir
        let tempDir = FileManager.default.temporaryDirectory
        let zipDir = tempDir.appendingPathComponent("zip_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: zipDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: zipDir) }

        print("🗜️  Creating zip archive with \(files.count) file(s)")

        // copy files, same names get " 2", " 3"
        var takenNames = Set<String>()
        for file in files {
            let name = uniqueName(for: file.name, taken: &takenNames)
            // copyItem copies symlinks as links, the zip would get a broken link
            try FileManager.default.copyItem(at: file.url.resolvingSymlinksInPath(), to: zipDir.appendingPathComponent(name))
        }

        // a single folder keeps its name, otherwise files_<timestamp>.zip
        let zipFileName: String
        if files.count == 1 && files[0].isDirectory {
            zipFileName = "\(files[0].name).zip"
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            zipFileName = "files_\(dateFormatter.string(from: Date())).zip"
        }

        // own folder per zip, two zips in the same second can't collide
        let outputDir = tempDir.appendingPathComponent("zip-out_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let zipURL = outputDir.appendingPathComponent(zipFileName)

        // run ditto to create zip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", zipDir.path, zipURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: outputDir)
            print("❌ Failed to create zip: \(error.localizedDescription)")
            throw ZipError.creationFailed
        }

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: zipURL.path) else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            print("❌ Zip creation failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
            try? FileManager.default.removeItem(at: outputDir)
            throw ZipError.creationFailed
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int64) ?? 0
        let sizeFormatted = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        print("✅ Zip created successfully: \(zipFileName) (\(sizeFormatted))")

        return zipURL
    }

    // "a.txt" taken -> "a 2.txt", case insensitive like the default file system
    static func uniqueName(for name: String, taken: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    static func cleanupTempFile(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                print("🗑️  Cleaned up temp file: \(url.lastPathComponent)")
            }
            // and the zip's own folder
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent.hasPrefix("zip-out_") {
                try? FileManager.default.removeItem(at: parent)
            }
        } catch {
            print("⚠️  Failed to cleanup temp file: \(error.localizedDescription)")
        }
    }
}
