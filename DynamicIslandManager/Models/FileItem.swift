import Foundation

struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let fileExtension: String
    let creationDate: Date?
    let isDirectory: Bool   // folders and packages, these get zipped before upload

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.fileExtension = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        self.isDirectory = values?.isDirectory == true || values?.isPackage == true

        // get file size and date
        let fileManager = FileManager.default
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            self.size = attributes[.size] as? Int64 ?? 0
            self.creationDate = attributes[.creationDate] as? Date
        } catch {
            self.size = 0
            self.creationDate = nil
        }
    }

    // formatted size
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    // file type
    var fileType: String {
        if fileExtension.isEmpty {
            return "Unknown"
        }
        return fileExtension.uppercased()
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}
