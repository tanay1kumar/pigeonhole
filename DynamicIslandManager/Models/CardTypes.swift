import Foundation

// suggestion card state, Equatable so views can animate on it

enum RowStatus: Equatable {
    case classifying
    case waiting            // dropped while a send was running
    case ready
    case sending
    case sent(fileId: String)
    case failed(String)
}

enum RetryAction: Equatable {
    case resend, undo, none
}

struct FileSuggestion: Identifiable, Equatable {
    let file: FileItem
    var ranked: [RankedDestination] = []
    var level: Level = .noIdea
    var chosen: Destination?
    var why = ""
    var status: RowStatus = .classifying
    var touched = false     // the user picked a folder for this row
    var reopened = false    // undo brought it back so its next send is a correction

    var id: UUID { file.id }

    // what the classifier put first
    var top: Destination? {
        ranked.first?.destination
    }

    // folders go up as zips
    var displayName: String {
        file.isDirectory ? file.name + ".zip" : file.name
    }

    var isSent: Bool {
        if case .sent = status { return true }
        return false
    }

    var sentFileId: String? {
        if case .sent(let id) = status { return id }
        return nil
    }
}

enum CardState: Equatable {
    case idle
    case classifying
    case suggesting
    case sending
    case sent(batchId: UUID)
    case undoing
    case error(String, retry: RetryAction)
}
