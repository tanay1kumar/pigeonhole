import SwiftUI

// where a dropped file should go (the plan §4.7). lives in the ~340x196 pt below the notch;
// nothing interactive sits under the notch itself
struct SuggestionCardView: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 40)       // clear of the notch
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.cardState {
        case .idle:
            EmptyView()
        case .classifying, .suggesting:
            if model.suggestions.count == 1, let row = model.suggestions.first {
                SingleFileCard(model: model, row: row)
            } else {
                MultiFileCard(model: model)
            }
        case .sending:
            ProgressCard(title: model.suggestions.count == 1 ? "Sending…" : "Sending \(model.suggestions.filter { !$0.isSent }.count) files…",
                         rows: model.suggestions)
        case .sent:
            SentCard(model: model)
        case .undoing:
            ProgressCard(title: "Undoing…", rows: [])
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
            // header
            HStack(spacing: 6) {
                Image(systemName: FileIcons.symbol(for: row.file))
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(row.file.formattedSize)")
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(height: 16)

            if row.status == .classifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at it…").font(.system(size: 13))
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
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    ChipRow(model: model, row: row, destinations: Array(row.ranked.prefix(3).map(\.destination)), showOther: true)
                case .noIdea:
                    Text("Where should it go?")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
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
                    .foregroundStyle(Color.accentColor)
                Text(row.chosen?.name ?? row.top?.name ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Send") {
                    model.send(row.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .debugFrame("send")
            }
            if !row.why.isEmpty {
                Text(row.why)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 26)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
    }
}

// the next suggestions as chips, and every destination behind "Other…"
private struct ChipRow: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion
    let destinations: [Destination]
    let showOther: Bool

    var body: some View {
        HStack(spacing: 6) {
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
        Menu {
            ForEach(model.destinationStore.destinations) { destination in
                Button(destination.name) {
                    model.send(row.id, to: destination)
                }
            }
        } label: {
            Text("Other…")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// "no idea": every destination, wrapping, at most 3 rows
private struct WrappingChips: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion
    let destinations: [Destination]

    var body: some View {
        FlowLayout(spacing: 6, maxRows: 3) {
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
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .frame(maxWidth: 120)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: several files

private struct MultiFileCard: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(model.suggestions.count) files")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(model.unpickedNoIdeaCount > 0 ? "Send all (pick \(model.unpickedNoIdeaCount) more)" : "Send all") {
                    model.sendAll()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canSendAll)
                .debugFrame("sendAll")
            }
            .frame(height: 22)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, row in
                        FileRow(model: model, row: row, index: index)
                    }
                }
            }
            .frame(maxHeight: 26 * 5)

            if let note = model.cardNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            CardFooter(model: model)
        }
    }
}

private struct FileRow: View {
    @ObservedObject var model: IslandViewModel
    let row: FileSuggestion
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcons.symbol(for: row.file))
                .frame(width: 16)
            Text(row.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if row.status == .classifying || row.status == .waiting {
                ProgressView().controlSize(.mini)
            } else {
                Menu {
                    ForEach(model.destinationStore.destinations) { destination in
                        Button(destination.name) {
                            model.choose(destination, for: row.id)
                        }
                    }
                } label: {
                    Text(label)
                        .foregroundStyle(row.chosen == nil ? Color.orange : Color.white)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
        HStack(spacing: 10) {
            Button(model.suggestions.count > 1 ? "Just upload (zip)" : "Just upload") {
                model.justUpload()
            }
            .disabled(model.cardState != .suggesting)
            .debugFrame("justUpload")
            Text("·").foregroundStyle(.white.opacity(0.4))
            Button {
                model.dismissCard()
            } label: {
                Image(systemName: "xmark")
            }
            .debugFrame("dismiss")
            .help("Forget these files")
            if model.authExpired {
                Button("Sign in again") { model.requestSignIn() }
                    .foregroundStyle(Color.accentColor)
                    .debugFrame("cardSignIn")
            }
            if model.suggestions.count == 1, let note = model.cardNote {
                Text(note)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .frame(height: 16)
    }
}

private struct ProgressCard: View {
    let title: String
    let rows: [FileSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title).font(.system(size: 14, weight: .medium))
            }
            ForEach(rows.prefix(5)) { row in
                HStack(spacing: 6) {
                    statusIcon(row.status)
                        .frame(width: 14)
                    Text(row.displayName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(row.chosen?.name ?? "").foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(_ status: RowStatus) -> some View {
        switch status {
        case .sent: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .sending: ProgressView().controlSize(.mini)
        default: Image(systemName: "circle").foregroundStyle(.white.opacity(0.3))
        }
    }
}

private struct SentCard: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 22))
                Text(model.sentSummary ?? "Sent")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Button("Undo") {
                    model.undo()
                }
                .controlSize(.regular)
                .debugFrame("undo")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ErrorCard: View {
    @ObservedObject var model: IslandViewModel
    let message: String
    let retry: RetryAction

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 22))
            Text(message)
                .font(.system(size: 13, weight: .medium))
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
                .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 10) {
                if model.authExpired {
                    Button("Sign in again") { model.requestSignIn() }
                        .buttonStyle(.borderedProminent)
                        .debugFrame("signInAgain")
                }
                if retry != .none {
                    Button("Retry") { model.retry() }
                        .buttonStyle(.borderedProminent)
                        .debugFrame("retry")
                }
                if retry == .resend && model.suggestions.contains(where: \.isSent) {
                    Button("Undo") { model.undo() }
                        .debugFrame("undo")
                }
                Button {
                    model.dismissCard()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .debugFrame("dismiss")
            }
            .controlSize(.small)
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
        if file.isDirectory { return "folder.fill" }
        switch file.fileExtension {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "mp3", "m4a", "wav", "aac", "flac": return "music.note"
        case "mov", "mp4", "m4v": return "film"
        case "zip", "dmg", "pkg": return "archivebox"
        default: return "doc"
        }
    }
}

// wraps chips into rows; anything past maxRows is hidden (macOS 13+ Layout)
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
        // overflow: out of sight
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
// previews: a confident single file, and three files with one still to pick
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
        .frame(width: DesignConstants.expandedWidth, height: DesignConstants.expandedHeight)
        .background(Color.black)
}

#Preview("several files") {
    SuggestionCardView(model: previewModel([("IMG_2041.heic", 2, .confident, "looks like: flower"),
                                            ("doc_final2.pdf", 0, .unsure, "PDF"),
                                            ("song.mp3", 0, .noIdea, "Audio")]))
        .frame(width: DesignConstants.expandedWidth, height: DesignConstants.expandedHeight)
        .background(Color.black)
}
#endif
