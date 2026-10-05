import SwiftUI

// picks existing drive folders (google picker) or creates new ones as destinations
@MainActor
class DestinationSetupModel: ObservableObject {
    @Published var newFolderName = ""
    @Published var newFolderParent: Destination?   // nil means my drive
    @Published var isCreating = false
    @Published var isPicking = false
    @Published var errorMessage: String?
    @Published var needsSignIn = false

    let store: DestinationStore
    let driveService: GoogleDriveService

    init(store: DestinationStore, driveService: GoogleDriveService) {
        self.store = store
        self.driveService = driveService
    }

    func chooseFromDrive() async {
        guard let config = DrivePickerConfig.load() else {
            errorMessage = "Google Picker isn't set up. Add GooglePickerAPIKey to Info.plist."
            return
        }

        errorMessage = nil
        needsSignIn = false
        isPicking = true
        do {
            let token = try await driveService.freshAccessToken()
            let maxItems = DestinationStore.maxCount - store.destinations.count
            try DrivePickerSession.start(config: config, accessToken: token, maxItems: maxItems) { [weak self] result in
                self?.handlePickerResult(result)
            }
        } catch {
            isPicking = false
            show(error, doing: "Couldn't open Google Drive.")
        }
    }

    // signed out shows a way back in; anything else the short reason
    private func show(_ error: Error, doing action: String) {
        let driveError = DriveError.from(error)
        if driveError.category == .authExpired {
            errorMessage = "Signed out of Google Drive."
            needsSignIn = true
        } else if driveError.category == .other && driveError.status == nil {
            // not an http error, the island's "Upload failed" wouldn't fit here
            errorMessage = "\(action) \(driveError.message ?? "Something went wrong.")"
        } else {
            errorMessage = "\(action) \(driveError.shortText)"
        }
    }

    func signInAgain() {
        errorMessage = nil
        needsSignIn = false
        NotificationCenter.default.post(name: .showSignIn, object: nil)
    }

    func cancelPicking() {
        DrivePickerSession.cancel()
    }

    private func handlePickerResult(_ result: DrivePickerResult) {
        isPicking = false
        switch result {
        case .picked(let folders):
            // picker doesn't tell us parent names, so path is just the folder
            for folder in folders {
                store.add(Destination(id: folder.id, name: folder.name, path: folder.name))
            }
        case .cancelled:
            break
        case .failed(let message):
            errorMessage = message
        }
    }

    func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        errorMessage = nil
        needsSignIn = false
        isCreating = true
        defer { isCreating = false }
        do {
            let folder = try await driveService.createFolder(named: name, in: newFolderParent?.id ?? "root")
            let path = [newFolderParent?.path ?? "My Drive", folder.name].joined(separator: " / ")
            store.add(Destination(id: folder.id, name: folder.name, path: path))
            newFolderName = ""
        } catch {
            show(error, doing: "Couldn't create the folder.")
        }
    }
}

struct DestinationSetupView: View {
    @ObservedObject var store: DestinationStore
    @StateObject private var model: DestinationSetupModel
    let onDone: () -> Void

    init(store: DestinationStore, driveService: GoogleDriveService, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        _model = StateObject(wrappedValue: DestinationSetupModel(store: store, driveService: driveService))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                addPanel
                selectedList
                    .frame(width: 230)
            }

            footer
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where should dropped files go?")
                .font(.system(size: 20, weight: .bold))
            Text("Pick up to \(DestinationStore.maxCount) Drive folders. When you drop a file on the island, it'll suggest one of these.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            // existing folders via google picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Use folders you already have")
                    .font(.system(size: 13, weight: .semibold))

                Button {
                    Task { await model.chooseFromDrive() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isPicking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "externaldrive.badge.icloud")
                        }
                        Text("Choose from Google Drive…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .controlSize(.large)
                .disabled(model.isPicking || store.isFull)

                if model.isPicking {
                    HStack {
                        Text("Finish choosing in your browser, then come back here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelPicking() }
                            .controlSize(.small)
                    }
                } else {
                    Text("Opens in your browser. The app can only see the folders you pick, never the rest of your Drive.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // brand new folder
            VStack(alignment: .leading, spacing: 8) {
                Text("Or make a new one")
                    .font(.system(size: 13, weight: .semibold))

                TextField("Folder name, e.g. Receipts", text: $model.newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.createFolder() } }

                HStack {
                    Picker("Inside", selection: $model.newFolderParent) {
                        Text("My Drive").tag(Destination?.none)
                        ForEach(store.destinations) { destination in
                            Text(destination.name).tag(Destination?.some(destination))
                        }
                    }
                    .fixedSize()

                    Spacer()

                    Button("Create & Add") {
                        Task { await model.createFolder() }
                    }
                    .disabled(model.newFolderName.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isCreating
                              || store.isFull)
                }
            }

            if let error = model.errorMessage {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    if model.needsSignIn {
                        Button("Sign in again") { model.signInAgain() }
                            .controlSize(.small)
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        // parent got removed from the list
        .onChange(of: store.destinations) { _, destinations in
            if let parent = model.newFolderParent, !destinations.contains(parent) {
                model.newFolderParent = nil
            }
        }
    }

    private var selectedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinations (\(store.destinations.count)/\(DestinationStore.maxCount))")
                .font(.system(size: 13, weight: .semibold))

            if store.destinations.isEmpty {
                Text("Nothing picked yet. Add folders like Receipts, School or Screenshots.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.destinations) { destination in
                            destinationRow(destination)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func destinationRow(_ destination: Destination) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(destination.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                store.remove(destination.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            if store.isFull {
                Text("That's the max. Remove one to add another.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.destinations.isEmpty ? "Skip for Now" : "Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
    }
}
