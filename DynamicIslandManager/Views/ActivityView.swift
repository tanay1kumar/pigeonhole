import SwiftUI

// the last sends, newest first, opened from the activity tile
// relative times are worked out once when the panel opens, nothing ticks
struct ActivityView: View {
    @ObservedObject var activity: ActivityStore
    let model: IslandViewModel
    @State private var opened = Date()

    var body: some View {
        DetailPanel(title: "Activity", onBack: { model.show(.home) }) {
            if activity.entries.isEmpty {
                PanelNote(symbol: "clock.arrow.circlepath", text: "No sends yet")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summaryText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    rows
                }
            }
        }
    }

    private var summaryText: String {
        let week = activity.summary()
        guard week.files > 0 else { return "Nothing this week" }
        return "\(week.files) file\(week.files == 1 ? "" : "s") · \(StorageText.bytes(week.bytes)) this week"
    }

    @ViewBuilder
    private var rows: some View {
        let shown = Array(activity.entries.prefix(20))
        let formatter = RelativeDateTimeFormatter()
        let list = VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                ActivityRow(entry: entry, when: formatter.localizedString(for: entry.date, relativeTo: opened), index: index)
            }
        }
        // a scroll view is an appkit view underneath, only once the rows don't fit
        if shown.count > 5 {
            ScrollView {
                list
            }
            .scrollIndicators(.never)
        } else {
            list
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    let when: String
    let index: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            // a button like the rest of the island, it takes the first click
            Button {
                LinkActions.open(entry)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: FileIcons.symbol(forName: entry.name))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 16)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // no lower priority, a short folder stays whole and the name truncates
                    Text("→ \(entry.destinationName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(when)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(entry.kind == .savedToMac ? "Shows it in Finder" : "Opens it in Google Drive")
            .debugFrame("activity-\(index)")
            // always laid out, so hovering doesn't push the time over
            Button {
                if let url = entry.driveURL {
                    LinkActions.copy([url])
                }
            } label: {
                Image(systemName: "link")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy link")
            .accessibilityLabel("Copy link")
            .opacity(showsLink ? 1 : 0)
            .allowsHitTesting(showsLink)
            .accessibilityHidden(entry.driveURL == nil)
            .debugFrame("activity-link-\(index)")
        }
        .font(.system(size: 12))
        .frame(height: 24)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0))
        )
        .onHover { isHovered = $0 }
    }

    private var showsLink: Bool {
        isHovered && entry.driveURL != nil
    }
}
