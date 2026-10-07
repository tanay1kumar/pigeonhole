import SwiftUI

// the storage panel, the bar, the numbers under it and a way to google's page
struct StorageView: View {
    @ObservedObject var storage: StorageStatus
    let model: IslandViewModel

    var body: some View {
        DetailPanel(title: "Storage", onBack: { model.show(.home) }) {
            if let about = storage.about {
                VStack(alignment: .leading, spacing: 8) {
                    // a failed refresh keeps the last numbers, dimmed
                    Group {
                        Text(StorageText.summary(about))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .accessibilityValue(storage.isStale ? "not up to date" : "")
                        // no limit, a bar of usage alone would read as a full drive
                        if about.limit != nil {
                            StorageBar(about: about)
                        }
                    }
                    .opacity(storage.isStale ? 0.55 : 1)
                    StorageLegend(about: about)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            if about.trash > 0 {
                                Text("Trash: \(StorageText.quota(about.trash))")
                            }
                            if let email = about.user?.emailAddress {
                                Text(email)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Manage storage…") {
                            LinkActions.openWeb(StorageText.manageURL)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .debugFrame("manageStorage")
                    }
                }
            } else {
                PanelNote(symbol: "externaldrive", text: storage.placeholder)
            }
        }
    }

}

// what the bar's colours are, the island's panel and settings both use it
struct StorageLegend: View {
    let about: DriveAbout

    var body: some View {
        HStack(spacing: 12) {
            dot(Color.accentColor, "Drive", about.usageInDrive)
            dot(Color.orange, "Other", about.otherUsage)
            if let free = about.free {
                dot(Color.gray.opacity(0.5), "Free", free)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func dot(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(label) \(StorageText.quota(bytes))")
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// drive, the rest of google's storage, and what's free
struct StorageBar: View {
    let about: DriveAbout

    var body: some View {
        GeometryReader { proxy in
            let total = Double(max(about.limit ?? about.usage, 1))
            let drive = CGFloat(Double(about.usageInDrive) / total) * proxy.size.width
            let other = CGFloat(Double(about.otherUsage) / total) * proxy.size.width
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(0, min(drive, proxy.size.width)))
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: max(0, min(other, proxy.size.width - drive)))
                Rectangle()
                    .fill(Color.white.opacity(0.15))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 8)
        // the summary line above and the legend already say it
        .accessibilityHidden(true)
    }
}

enum StorageText {
    static let manageURL = URL(string: "https://one.google.com/storage")!

    // file sizes, the way finder shows them
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // google counts quota in 1024s, a 15 GB plan is 16106127360 bytes
    static func quota(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    static func summary(_ about: DriveAbout) -> String {
        if let free = about.free, let limit = about.limit {
            return "\(quota(free)) free of \(quota(limit))"
        }
        return "\(quota(about.usage)) used · Unlimited"
    }
}
