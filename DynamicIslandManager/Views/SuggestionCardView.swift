import SwiftUI

// where a dropped file should go, below the notch band
// buttons and menus are drawn in swiftui, no appkit controls to lay out while the island opens
struct SuggestionCardView: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        #if DEBUG
        let _ = BodyCounts.note("SuggestionCardView")
        #endif
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, DesignConstants.notchBand + 4)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch model.cardState {
        case .idle:
            EmptyView()
        case .classifying, .suggesting:
            if model.suggestions.count == 1, let row = model.suggestions.first {
                SingleFileCard(model: model, row: row)
            } else if model.suggestions.isEmpty {
                // the dropped files haven't loaded yet, the footer keeps dismiss
                Text("Getting the files…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CardFooter(model: model)
            } else {
                MultiFileCard(model: model)
            }
        case .sending:
            ProgressCard(model: model)
        case .sent:
            SentCard(model: model)
        case .undoing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Undoing…").font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message, let retry):
            ErrorCard(model: model, message: message, retry: retry)
        }
    }
}

// MARK: one file

private struct SingleFileCard: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FileHeader(model: model, row: row)

            // without folders there's nothing to wait for
            if !model.hasDestinations {
                NoFoldersNote(model: model)
            } else if row.status == .classifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at it…")
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                switch row.level {
                case .confident:
                    suggestionBox
                    ChipRow(model: model, row: row, destinations: Array(row.ranked.dropFirst().prefix(2).map(\.destination)), showOther: true)
                case .unsure:
                    Text(row.why.isEmpty ? "Not sure, maybe one of these:" : "Not sure · \(row.why)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ChipRow(model: model, row: row, destinations: Array(row.ranked.prefix(3).map(\.destination)), showOther: true)
                case .noIdea:
                    Text("Where should it go?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    WrappingChips(model: model, row: row, destinations: model.destinationStore.destinations)
                    // long names can need more than 3 rows of chips
                    OtherMenu(model: model, row: row)
                        .debugFrame("other")
                }
            }

            Spacer(minLength: 0)
            CardFooter(model: model)
        }
    }

    private var suggestionBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(row.chosen?.name ?? row.top?.name ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Send") {
                    model.send(row.id)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .debugFrame("send")
            }
            if !row.why.isEmpty {
                Text(row.why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

// file name, type symbol, the format it goes as, and size
private struct FileHeader: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcons.symbol(for: row.file))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(row.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            FormatPill(model: model, row: row, index: 0)
            Text("· \(row.file.formattedSize)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .frame(height: 16)
    }
}

// a warning under the rows, or what save to mac just saved
private struct CardNoteLine: View {
    @ObservedObject var model: IslandViewModel
    let note: String

    var body: some View {
        HStack(spacing: 8) {
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(model.savedFiles.isEmpty || model.someNotSaved ? Color.orange : Color.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            if !model.savedFiles.isEmpty {
                Button("Show in Finder") {
                    LinkActions.reveal(model.savedFiles)
                }
                .buttonStyle(SecondaryButtonStyle())
                .debugFrame("showSaved")
            }
        }
    }
}

// what the file goes as, kept or one of the formats macos can make
private struct FormatPill: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion
    let index: Int
    var compact = false

    var body: some View {
        let options = row.convertOptions
        if !options.isEmpty {
            let original = row.file.fileExtension.uppercased()
            MenuButton(items: [MenuChoice(title: "Keep as \(original)", checked: row.convertTo == nil) {
                model.setConvert(nil, for: row.id)
            }] + options.map { format in
                MenuChoice(title: format.title, checked: row.convertTo == format) {
                    model.setConvert(format, for: row.id)
                }
            }) {
                HStack(spacing: 2) {
                    Text(row.convertTo.map { "→ \($0.title)" } ?? original)
                    Image(systemName: "chevron.down")
                        .font(.system(size: compact ? 6 : 7, weight: .bold))
                }
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .padding(.horizontal, compact ? 4 : 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(row.convertTo == nil ? 0.1 : 0.22)))
                .foregroundStyle(row.convertTo == nil ? Color.secondary : Color.white)
                .contentShape(Capsule())
            }
            .fixedSize()
            .accessibilityLabel("Format for \(row.displayName), " + (row.convertTo?.title ?? "Keep as \(original)"))
            .debugFrame("format-\(index)")
        }
    }
}

// no folders picked yet, the card still takes the file
private struct NoFoldersNote: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text("No folders yet")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Button("Choose folders…") {
                model.chooseFolders()
            }
            .buttonStyle(PrimaryButtonStyle())
            .debugFrame("chooseFolders")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

// next suggestions as chips, every destination under "Other..."
private struct ChipRow: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion
    let destinations: [Destination]
    let showOther: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(destinations) { destination in
                Chip(title: destination.name) {
                    model.send(row.id, to: destination)
                }
                .debugFrame("chip-\(destination.name)")
            }
            if showOther {
                OtherMenu(model: model, row: row)
                    .debugFrame("other")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }
}

private struct OtherMenu: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion

    var body: some View {
        MenuButton(items: model.destinationStore.destinations.map { destination in
            MenuChoice(title: destination.name) {
                model.send(row.id, to: destination)
            }
        }) {
            HStack(spacing: 2) {
                Text("Other…")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .fixedSize()
    }
}

// "no idea" shows every destination, wrapping, max 3 rows
private struct WrappingChips: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion
    let destinations: [Destination]

    var body: some View {
        FlowLayout(spacing: 4, maxRows: 3) {
            ForEach(destinations) { destination in
                Chip(title: destination.name) {
                    model.send(row.id, to: destination)
                }
                .debugFrame("chip-\(destination.name)")
            }
        }
    }
}

private struct Chip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .frame(maxWidth: 120)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send to \(title)")
        // voice control still answers to the name on the chip
        .accessibilityInputLabels([title])
    }
}

// MARK: several files

private struct MultiFileCard: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(model.suggestions.count) files")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.hasDestinations {
                    Button(model.unpickedNoIdeaCount > 0 ? "Send all (pick \(model.unpickedNoIdeaCount) more)" : "Send all") {
                        model.sendAll()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canSendAll)
                    .debugFrame("sendAll")
                } else {
                    Button("Choose folders…") {
                        model.chooseFolders()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .debugFrame("chooseFolders")
                }
            }
            .frame(height: 26)

            // a scroll view is an appkit view underneath, only when there are more than 5
            if model.suggestions.count > 5 {
                ScrollView {
                    rows
                }
                .frame(maxHeight: 26 * 5)
            } else {
                rows
            }

            if let note = model.cardNote {
                CardNoteLine(model: model, note: note)
            }
            Spacer(minLength: 0)
            CardFooter(model: model)
        }
    }
}

private extension MultiFileCard {
    var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, row in
                FileRow(model: model, row: row, index: index)
            }
        }
    }
}

private struct FileRow: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcons.symbol(for: row.file))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(row.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            FormatPill(model: model, row: row, index: index, compact: true)
            Spacer(minLength: 4)
            if (row.status == .classifying || row.status == .waiting) && model.hasDestinations {
                ProgressView().controlSize(.mini)
            } else if model.hasDestinations {
                MenuButton(items: model.destinationStore.destinations.map { destination in
                    MenuChoice(title: destination.name, checked: destination.id == row.chosen?.id) {
                        model.choose(destination, for: row.id)
                    }
                }) {
                    // a chevron like the format pill, so the folder reads as a menu
                    HStack(spacing: 2) {
                        Text(label)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(row.chosen == nil ? Color.orange : Color.white)
                    .contentShape(Rectangle())
                }
                .fixedSize()
                // the arrow and the question mark don't read aloud
                .accessibilityLabel("Folder for \(row.displayName), " + (row.chosen.map { $0.name + (row.level == .unsure && !row.touched ? ", not sure" : "") } ?? "none picked"))
                .debugFrame("row-\(index)")
            }
        }
        .font(.system(size: 12))
        .frame(height: 26)
    }

    private var label: String {
        guard let chosen = row.chosen else { return "Pick…" }
        // a question mark when the classifier wasn't sure and nobody changed it
        return "→ " + chosen.name + (row.level == .unsure && !row.touched ? "?" : "")
    }
}

// MARK: shared bits

private struct CardFooter: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button(model.suggestions.count > 1 ? "Just upload (zip)" : "Just upload") {
                model.justUpload()
            }
            .disabled(!model.canJustUpload)
            .debugFrame("justUpload")
            if model.suggestions.contains(where: { $0.convertTo != nil }) {
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Button("Save to Mac") {
                    model.saveToMac()
                }
                .disabled(!model.canSaveToMac)
                .help("Convert and save next to the originals, nothing goes to Drive")
                .debugFrame("saveToMac")
            }
            Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
            Button {
                model.dismissCard()
            } label: {
                Image(systemName: "xmark")
            }
            .debugFrame("dismiss")
            .help("Forget these files")
            .accessibilityLabel("Dismiss")
            if model.authExpired {
                Button("Sign in again…") { model.requestSignIn() }
                    .foregroundStyle(Color.accentColor)
                    .debugFrame("cardSignIn")
            }
            if model.suggestions.count == 1, let note = model.cardNote {
                CardNoteLine(model: model, note: note)
                    .layoutPriority(-1)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 16)
    }
}

// sending, one file says how far it got, several get a ring each, each with an x
private struct ProgressCard: View {
    @ObservedObject var model: IslandViewModel

    private var sending: [FileSuggestion] {
        model.progressRows
    }

    var body: some View {
        let rows = sending
        // the multi-file card's rows, so the names stay put when a send starts
        let listed = model.justUploadProgress == nil && rows.count > 1
        VStack(alignment: .leading, spacing: 4) {
            if listed {
                HStack(spacing: 8) {
                    headlineLabel(rows)
                    Spacer(minLength: 4)
                    stopButton(rows)
                }
                .frame(height: 26)
            } else {
                // one line is centered like the result after it, the x stays at the edge so the line doesn't move when it goes
                headlineLabel(rows)
                    .lineLimit(1)
                    .debugFrame("progressLine")
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        stopButton(rows)
                    }
                    .frame(height: 16)
            }
            if listed {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRows(rows).enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 8) {
                            statusIcon(row)
                                .frame(width: 16, height: 14)
                            Text(row.displayName).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            // saved next to the originals, the drive folder doesn't apply
                            if !model.savingToMac {
                                Text(row.chosen?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                            }
                            if canStop(row) {
                                Button {
                                    model.cancelSend(row.id)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .help("Stop this one")
                                .accessibilityLabel("Stop sending \(row.displayName)")
                                .debugFrame("cancel-\(index)")
                            }
                        }
                        .font(.system(size: 12))
                        .frame(height: 26)
                    }
                }
            }
        }
        // one line sits where the sent line will, only the list starts at the top
        .frame(maxWidth: .infinity, maxHeight: listed ? nil : .infinity, alignment: .leading)
    }

    private func headlineLabel(_ rows: [FileSuggestion]) -> some View {
        HStack(spacing: 8) {
            ProgressRing(fraction: model.savingToMac ? model.saveDone : headline ?? batchDone(rows),
                         label: model.savingToMac ? "Saving" : "Sending")
                .frame(width: 16, height: 16)
            Text(title(rows))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func stopButton(_ rows: [FileSuggestion]) -> some View {
        if let cancel = headlineCancel(rows) {
            Button(action: cancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Stop, nothing goes to Drive")
            .accessibilityLabel("Stop sending")
            .debugFrame("cancelSend")
        }
    }

    // just upload's one upload, or the only row
    private var headline: Double? {
        if let progress = model.justUploadProgress {
            return progress
        }
        let rows = sending
        return rows.count == 1 ? rows[0].progress : nil
    }

    // several rows, sent and failed ones count as done
    private func batchDone(_ rows: [FileSuggestion]) -> Double? {
        guard !rows.isEmpty else { return nil }
        let done = rows.reduce(0.0) { $0 + ($1.isBusy ? ($1.progress ?? 0) : 1) }
        return done / Double(rows.count)
    }

    // past 5 rows the list follows the upload, the rows after it stay in view so they can be taken out
    private func visibleRows(_ rows: [FileSuggestion]) -> ArraySlice<FileSuggestion> {
        let current = rows.firstIndex(where: \.isBusy) ?? 0
        let start = min(max(0, current - 1), max(0, rows.count - 5))
        return rows[start...].prefix(5)
    }

    private func title(_ rows: [FileSuggestion]) -> String {
        if model.savingToMac {
            return "Saving to your Mac…"
        }
        if model.justUploadConverting {
            return "Converting…"
        }
        if let progress = headline {
            return progress > 0 ? "Uploading \(Int((progress * 100).rounded(.down)))%" : "Uploading…"
        }
        if rows.count == 1, rows[0].status == .converting {
            return "Converting to \(rows[0].convertTo?.title ?? "")…"
        }
        let left = rows.filter(\.isBusy).count
        return left == 1 ? "Sending 1 file…" : "Sending \(left) files…"
    }

    // converting, or uploading with bytes still to go, save to mac runs to the end
    private func canStop(_ row: FileSuggestion) -> Bool {
        !model.savingToMac && (row.status == .converting || (row.isSending && (row.progress ?? 0) < 1))
    }

    // once every byte is in it's too late to stop
    private func headlineCancel(_ rows: [FileSuggestion]) -> (() -> Void)? {
        if let progress = model.justUploadProgress {
            return progress < 1 ? { model.cancelJustUpload() } : nil
        }
        if rows.count == 1, canStop(rows[0]) {
            let id = rows[0].id
            return { model.cancelSend(id) }
        }
        return nil
    }

    @ViewBuilder
    private func statusIcon(_ row: FileSuggestion) -> some View {
        switch row.status {
        case .sent: Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Sent")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Failed")
        case .sending(let progress): ProgressRing(fraction: progress)
        case .converting: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).accessibilityLabel("Converting")
        default: Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityLabel("Waiting")
        }
    }

}

// how much of a file drive has, drawn in swiftui, a dot until the first bytes arrive
struct ProgressRing: View {
    let fraction: Double?
    // save to mac fills the header ring too, nothing goes to drive then
    var label = "Sending"

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction ?? 0, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
        .accessibilityElement()
        .accessibilityLabel(label)
        // down like the title, so it never says 100 with bytes still to go
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "starting")
    }
}

private struct SentCard: View {
    @ObservedObject var model: IslandViewModel
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.system(size: 22))
                .accessibilityHidden(true)
            Text(model.sentSummary ?? "Sent")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.suggestions.contains(where: { $0.isSent && $0.driveLink != nil }) {
                Button(copied ? "Copied" : "Copy link") {
                    guard model.copySentLinks() else { return }
                    copied = true
                    // another click starts the 1.5 s over
                    copiedReset?.cancel()
                    copiedReset = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .debugFrame("copyLink")
            }
            Button("Undo") {
                model.undo()
            }
            .buttonStyle(SecondaryButtonStyle())
            .debugFrame("undo")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorCard: View {
    @ObservedObject var model: IslandViewModel
    let message: String
    let retry: RetryAction

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .orange)
                .font(.system(size: 22))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            // which files didn't go, so retry is clear about what it sends
            if !failedRows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(failedRows.prefix(3)) { row in
                        Text("\(row.displayName) → \(row.chosen?.name ?? "?")")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if failedRows.count > 3 {
                        Text("and \(failedRows.count - 3) more")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if model.authExpired {
                    Button("Sign in again…") { model.requestSignIn() }
                        .buttonStyle(PrimaryButtonStyle())
                        .debugFrame("signInAgain")
                }
                if retry != .none {
                    Button("Retry") { model.retry() }
                        .buttonStyle(PrimaryButtonStyle())
                        .debugFrame("retry")
                }
                if retry == .resend && model.suggestions.contains(where: \.isSent) {
                    Button("Undo") { model.undo() }
                        .buttonStyle(SecondaryButtonStyle())
                        .debugFrame("undo")
                }
                Button {
                    model.dismissCard()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Dismiss")
                .debugFrame("dismiss")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var failedRows: [FileSuggestion] {
        guard retry == .resend else { return [] }
        return model.suggestions.filter {
            if case .failed = $0.status { return true }
            return false
        }
    }
}

enum FileIcons {
    static func symbol(for file: FileItem) -> String {
        file.isDirectory ? "folder.fill" : symbol(forExtension: file.fileExtension)
    }

    // activity only has the name, a zipped folder is an archive
    static func symbol(forName name: String) -> String {
        symbol(forExtension: (name as NSString).pathExtension.lowercased())
    }

    private static func symbol(forExtension fileExtension: String) -> String {
        switch fileExtension {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "mp3", "m4a", "wav", "aif", "aiff", "aac", "flac", "caf": return "music.note"
        case "mov", "mp4", "m4v": return "film"
        case "zip", "dmg", "pkg": return "archivebox"
        default: return "doc"
        }
    }
}

// wraps chips into rows, anything past maxRows is hidden (macos 13+ Layout)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var maxRows = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var placed = Set<Int>()
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                placed.insert(index)
            }
            y += row.height + spacing
        }
        // overflow, out of sight
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                guard rows.count < maxRows else { break }
                rows.append(Row())
            }
            let gap: CGFloat = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

#if DEBUG
// previews for a confident single file and three files with one left to pick
@MainActor
private func previewModel(_ rows: [(name: String, top: Int, level: Level, why: String)]) -> IslandViewModel {
    let destinations = [Destination(id: "p-resumes", name: "Resumes", path: "Resumes"),
                        Destination(id: "p-receipts", name: "Receipts", path: "Receipts"),
                        Destination(id: "p-flowers", name: "Flowers", path: "Flowers")]
    let store = DestinationStore()
    store.debugUseInMemory(destinations)
    let model = IslandViewModel(destinationStore: store)
    model.suggestions = rows.map { row in
        var suggestion = FileSuggestion(file: FileItem(url: URL(fileURLWithPath: "/tmp/" + row.name)))
        suggestion.ranked = destinations.indices.map { index in
            RankedDestination(destination: destinations[(row.top + index) % destinations.count], raw: index == 0 ? 0.3 : 0.05, p: index == 0 ? 0.8 : 0.1)
        }
        suggestion.level = row.level
        suggestion.chosen = row.level == .noIdea ? nil : suggestion.ranked.first?.destination
        suggestion.why = row.why
        suggestion.status = .ready
        return suggestion
    }
    model.cardState = .suggesting
    return model
}

#Preview("one file") {
    SuggestionCardView(model: previewModel([("doc_final2.pdf", 0, .confident, "PDF · mentions: bachelor, education")]))
        .frame(width: DesignConstants.expandedWidth, height: DesignConstants.singleCardHeight)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}

#Preview("several files") {
    SuggestionCardView(model: previewModel([("IMG_2041.heic", 2, .confident, "looks like: flower"),
                                            ("doc_final2.pdf", 0, .unsure, "PDF"),
                                            ("song.mp3", 0, .noIdea, "Audio")]))
        .frame(width: DesignConstants.expandedWidth, height: DesignConstants.expandedHeight)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}
#endif
