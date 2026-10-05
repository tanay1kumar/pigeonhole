import Foundation

enum CubeType: String, CaseIterable, Identifiable {
    case upload
    case convert
    case uploadCount
    case storageLeft
    case recentActivity
    case destinations

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .upload:
            return "icloud.and.arrow.up"
        case .convert:
            return "arrow.triangle.2.circlepath"
        case .uploadCount:
            return "arrow.up.doc"
        case .storageLeft:
            return "externaldrive"
        case .recentActivity:
            return "clock"
        case .destinations:
            return "folder.badge.gearshape"
        }
    }

    var title: String {
        switch self {
        case .upload:
            return "Upload"
        case .convert:
            return "Convert File"
        case .uploadCount:
            return "Uploads"
        case .storageLeft:
            return "Storage"
        case .recentActivity:
            return "Activity"
        case .destinations:
            return "Destinations"
        }
    }
}
