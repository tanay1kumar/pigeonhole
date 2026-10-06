import AppKit

// opening and copying drive links, scenarios log instead of opening a browser
@MainActor
enum LinkActions {
    // tests copy into their own pasteboard, never the user's
    static var pasteboard = NSPasteboard.general
    #if DEBUG
    static var logOnly = false
    static var opened: [URL] = []
    #endif

    // a drive file opens its page, a saved one shows in finder
    static func open(_ entry: ActivityEntry) {
        switch entry.kind {
        case .savedToMac:
            guard let path = entry.localPath else { return }
            reveal([URL(fileURLWithPath: path)])
        case .sent, .justUploaded:
            guard let url = entry.driveURL else { return }
            openWeb(url)
        }
    }

    static func openWeb(_ url: URL) {
        #if DEBUG
        if logOnly {
            print("would open \(url.absoluteString)")
            opened.append(url)
            return
        }
        #endif
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ urls: [URL]) {
        #if DEBUG
        if logOnly {
            print("would show \(urls.map(\.lastPathComponent)) in finder")
            opened += urls
            return
        }
        #endif
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // a batch goes one link per line
    @discardableResult
    static func copy(_ links: [URL]) -> Bool {
        guard !links.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string)
    }
}
