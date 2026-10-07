import SwiftUI

// picks existing drive folders (google picker) or creates new ones as destinations
@MainActor
class DestinationSetupModel: ObservableObject {
    @Published var newFolderName = ""
    @Published var newFolderParentId: String?   // nil means my drive
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
            errorMessage = "Google Picker isn't set up, add GooglePickerAPIKey to Info.plist"
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
            show(error, doing: "Couldn't open Google Drive")
        }
    }

    // signed out shows a way back in, anything else just the short reason
    private func show(_ error: Error, doing action: String) {
        let driveError = DriveError.from(error)
        if driveError.category == .authExpired {
            errorMessage = "Signed out of Google Drive"
            needsSignIn = true
        } else if driveError.category == .other && driveError.status == nil {
            // not an http error, its own message says more than the generic one
            errorMessage = "\(action): \(driveError.message ?? "Something went wrong")"
        } else {
            errorMessage = "\(action): \(driveError.shortText)"
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
            let parent = store.destinations.first { $0.id == newFolderParentId }
            let folder = try await driveService.createFolder(named: name, in: parent?.id ?? "root")
            let path = [parent?.path ?? "My Drive", folder.name].joined(separator: " / ")
            store.add(Destination(id: folder.id, name: folder.name, path: path))
            newFolderName = ""
        } catch {
            show(error, doing: "Couldn't create the folder")
        }
    }
}

struct DestinationSetupView: View {
    @ObservedObject var store: DestinationStore
    @StateObject private var model: DestinationSetupModel
    let classifier: DestinationClassifier?
    let learningStore: LearningStore?
    let onDone: () -> Void
    @State private var confirmingReset = false
    @State private var resetDone = false

    init(store: DestinationStore, driveService: GoogleDriveService, classifier: DestinationClassifier? = nil,
         learningStore: LearningStore? = nil, onDone: @escaping () -> Void) {
        self.classifier = classifier
        self.learningStore = learningStore
        self.store = store
        self.onDone = onDone
        _model = StateObject(wrappedValue: DestinationSetupModel(store: store, driveService: driveService))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
            // grouped forms like the other panes, so the boxes and background match
            HStack(alignment: .top, spacing: 0) {
                addPanel
                selectedList
                    .frame(width: 270)
            }
            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .groupedFormBackground()
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where should dropped files go?")
                .font(.system(size: 15, weight: .semibold))
            Text("Pick up to \(DestinationStore.maxCount) Drive folders. When you drop a file on the island, it'll suggest one of these.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addPanel: some View {
        Form {
            // existing folders via google picker
            Section("Use folders you already have") {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await model.chooseFromDrive() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isPicking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "externaldrive.badge.icloud")
                                    .accessibilityHidden(true)
                            }
                            Text("Choose from Google Drive…")
                        }
                        .frame(maxWidth: .infinity)
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }

            // brand new folder
            Section("Or make a new one") {
                TextField("Name", text: $model.newFolderName, prompt: Text("e.g. Receipts"))
                    .onSubmit { Task { await model.createFolder() } }
                Picker("Inside", selection: $model.newFolderParentId) {
                    Text("My Drive").tag(String?.none)
                    ForEach(store.destinations) { destination in
                        Text(destination.name).tag(String?.some(destination.id))
                    }
                }
                HStack {
                    Spacer()
                    Button("Create and add") {
                        Task { await model.createFolder() }
                    }
                    .disabled(model.newFolderName.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isCreating
                              || store.isFull)
                }
            }

            if let error = model.errorMessage {
                Section {
                    HStack(spacing: 8) {
                        // orange text is about 2:1 in light mode, only the icon keeps the color
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.system(size: 12))
                        if model.needsSignIn {
                            Spacer(minLength: 4)
                            Button("Sign in again…") { model.signInAgain() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // parent got removed from the list
        .onChange(of: store.destinations) { _, destinations in
            if let parentId = model.newFolderParentId, !destinations.contains(where: { $0.id == parentId }) {
                model.newFolderParentId = nil
            }
        }
    }

    private var selectedList: some View {
        Form {
            Section("Destinations (\(store.destinations.count)/\(DestinationStore.maxCount))") {
                if store.destinations.isEmpty {
                    Text("Nothing picked yet. Add folders like Receipts, School or Screenshots.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.destinations) { destination in
                        DestinationRow(store: store, destination: destination,
                                       learnedCount: learningStore?.data(for: destination.id)?.examples.count ?? 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            // forget what was learned, asks once inline
            if confirmingReset {
                Text("Forget everything it learned?")
                    .font(.system(size: 12))
                Button("Cancel") { confirmingReset = false }
                    .controlSize(.small)
                Button("Reset") {
                    confirmingReset = false
                    resetDone = true
                    let classifier = classifier
                    Task { await classifier?.reset() }
                }
                .controlSize(.small)
                .foregroundStyle(.red)
                .debugFrame("resetConfirm")
            } else if resetDone {
                Label("Learning reset", systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if classifier != nil {
                Button("Reset learning") { confirmingReset = true }
                    .controlSize(.small)
                    .debugFrame("resetLearning")
            }
            if store.isFull {
                Text("That's the max. Remove one to add another.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.destinations.isEmpty ? "Skip for now" : "Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .debugFrame("done")
        }
    }
}

// one destination row, name, path, and its hint below
private struct DestinationRow: View {
    @ObservedObject var store: DestinationStore
    let destination: Destination
    let learnedCount: Int
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(destination.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                // its own line, after the path the head truncation cut the path first
                if learnedCount > 0 {
                    Text("Learned from \(learnedCount) file\(learnedCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // the longer placeholder didn't fit the column so it gets its own line
                TextField("Hint", text: $draft, prompt: Text("e.g. my CVs and cover letters"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($editing)
                    .onSubmit(commit)
                    .accessibilityLabel("Hint for \(destination.name)")
                    .debugFrame("hint-\(destination.name)")
            }
            // fills the row, a spacer here took width from the hint
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.remove(destination.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from the list, the folder stays in Drive")
            .accessibilityLabel("Remove \(destination.name)")
            .debugFrame("remove-\(destination.name)")
        }
        .padding(.vertical, 2)
        .onAppear { draft = destination.hint ?? "" }
        .onDisappear(perform: commit)
        // closing the window with a hint typed and no return still keeps it
        // a closed window keeps its views, so onDisappear alone would wait for the next open
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object is SettingsWindow {
                commit()
            }
        }
        // the last open's rows can save after this one read the store
        .onChange(of: destination.hint) { _, hint in
            if !editing {
                draft = hint ?? ""
            }
        }
        // saved on return or when focus leaves, not per keystroke
        .onChange(of: editing) { _, isEditing in
            if !isEditing {
                commit()
            }
        }
    }

    private func commit() {
        store.updateHint(id: destination.id, hint: draft)
    }
}
