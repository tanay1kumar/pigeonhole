import SwiftUI
import Combine

// what the island shows in place of the cube grid while something's going on
struct IslandStatus: Equatable {
    enum Kind: Equatable {
        case working, success, failure, signIn
    }

    let kind: Kind
    let message: String
}

@MainActor
class IslandViewModel: ObservableObject {
    // how long things stay up, tests shrink these
    struct Timing {
        var resultLinger: Double = 3    // success/error text, then the island may close
        var unattended: Double = 30     // a pinned banner nobody looks at folds away
        var parkRecheck: Double = 1     // pointer still over the island, check again
    }

    // state vars
    @Published var currentState: IslandState = .collapsed
    @Published var cubeOrder: [CubeType] = [
        .upload,
        .convert,
        .uploadCount,
        .storageLeft,
        .recentActivity,
        .destinations
    ]
    @Published var draggedCube: CubeType?
    @Published var droppedFiles: [FileItem] = []
    @Published private(set) var status: IslandStatus?
    @Published private(set) var statusPinned = false
    @Published private(set) var authExpired = false
    @Published private(set) var isUploading = false
    @Published var parked = false
    // the upload cube's last result, for logs and the scenario cleanup
    private(set) var lastUploadedFile: DriveFile?

    // a pinned status keeps the island open, unless it was parked
    var holdsExpanded: Bool {
        statusPinned && !parked
    }

    let driveService: DriveUploading
    var timing = Timing()
    // set by IslandView, tells whether the pointer is over the expanded island
    var pointerIsOverIsland: () -> Bool = { false }

    private var statusTask: Task<Void, Never>?
    private var parkTask: Task<Void, Never>?
    private var signInObserver: AnyCancellable?

    init(driveService: DriveUploading = GoogleDriveService()) {
        self.driveService = driveService

        // sign-in worked again, drop the banner
        signInObserver = NotificationCenter.default.publisher(for: .didSignIn)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.signedIn()
                }
            }
    }

    // expand collapse. a drag passing by opens the island but leaves a parked banner parked,
    // so the island closes again after the drag; only a hover on the notch brings the banner back
    func expand(fromDrag: Bool = false) {
        withAnimation(AnimationConstants.expand) {
            currentState = .expanded
        }
        guard !fromDrag else { return }
        parked = false
        // count the unattended time again from now
        if status?.kind == .signIn {
            scheduleParking()
        }
    }

    func collapse() {
        // every collapse path ends up here, a pinned status keeps the island open
        guard !holdsExpanded else { return }
        withAnimation(AnimationConstants.collapse) {
            currentState = .collapsed
        }
    }

    // cube reordering
    func moveCube(from source: IndexSet, to destination: Int) {
        cubeOrder.move(fromOffsets: source, toOffset: destination)
    }

    func reorderCube(from draggedCubeType: CubeType, to targetCube: CubeType) {
        guard let fromIndex = cubeOrder.firstIndex(of: draggedCubeType),
              let toIndex = cubeOrder.firstIndex(of: targetCube),
              fromIndex != toIndex else {
            draggedCube = nil
            return
        }

        // swap cubes
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            cubeOrder.swapAt(fromIndex, toIndex)
        }

        // clear drag
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.draggedCube = nil
        }
    }

    // file handling
    func addFiles(_ files: [FileItem]) {
        droppedFiles.append(contentsOf: files)
        print("added \(files.count) files, total: \(droppedFiles.count)")
    }

    func clearFiles() {
        let fileCount = droppedFiles.count
        droppedFiles.removeAll()
        print("cleared \(fileCount) files")
    }

    // upload cube: one file as-is, several files (or a folder) zipped, all into my drive.
    // on failure the files stay queued so another tap retries
    @discardableResult
    func uploadDroppedFiles() async -> Bool {
        guard !isUploading, !droppedFiles.isEmpty else { return false }
        let batch = droppedFiles
        isUploading = true
        defer { isUploading = false }

        var item = batch[0]
        var zipURL: URL?
        if batch.count > 1 || item.isDirectory {
            let what = batch.count > 1 ? "\(batch.count) files" : item.name
            show(IslandStatus(kind: .working, message: "Zipping \(what)…"))
            do {
                // ditto blocks, keep it off main
                let url = try await Task.detached { try ZipUtility.zipFiles(batch) }.value
                zipURL = url
                item = FileItem(url: url)
            } catch {
                print("zip failed: \(error.localizedDescription)")
                showResult(IslandStatus(kind: .failure, message: "Couldn't zip the files"))
                return false
            }
        }
        defer {
            if let zipURL {
                ZipUtility.cleanupTempFile(at: zipURL)
            }
        }

        show(IslandStatus(kind: .working, message: "Uploading \(item.name)…"))
        do {
            lastUploadedFile = try await driveService.uploadFile(item, to: nil)
            // only clear what was sent, files dropped meanwhile stay queued
            let sent = Set(batch.map(\.id))
            droppedFiles.removeAll { sent.contains($0.id) }
            showResult(IslandStatus(kind: .success, message: "Uploaded to My Drive"))
            return true
        } catch {
            handleDriveError(error)
            return false
        }
    }

    func requestSignIn() {
        NotificationCenter.default.post(name: .showSignIn, object: nil)
    }

    // MARK: status

    private func handleDriveError(_ error: Error) {
        let driveError = DriveError.from(error)
        print("upload failed: \(driveError.localizedDescription)")
        if driveError.category == .authExpired {
            // the only error that needs the user, it stays until they sign in
            authExpired = true
            show(IslandStatus(kind: .signIn, message: "Signed out of Google Drive"))
            scheduleParking()
        } else {
            showResult(IslandStatus(kind: .failure, message: driveError.shortText))
        }
    }

    // pinned until replaced or cleared
    private func show(_ newStatus: IslandStatus) {
        statusTask?.cancel()
        statusTask = nil
        parkTask?.cancel()
        parkTask = nil
        status = newStatus
        statusPinned = true
        parked = false
        if currentState == .collapsed {
            expand()
        }
    }

    // results stay up a few seconds, then the island may close again
    private func showResult(_ result: IslandStatus) {
        show(result)
        let delay = timing.resultLinger
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.status = nil
            self.statusPinned = false
            self.statusTask = nil
        }
    }

    private func signedIn() {
        guard authExpired else { return }
        authExpired = false
        parkTask?.cancel()
        parkTask = nil
        if status?.kind == .signIn {
            status = nil
            statusPinned = false
            parked = false
        }
        print("signed in again, banner cleared")
    }

    #if DEBUG
    // scenarios start each run from a clean island
    func debugResetStatus() {
        statusTask?.cancel()
        parkTask?.cancel()
        status = nil
        statusPinned = false
        parked = false
        authExpired = false
    }
    #endif

    // a banner nobody looks at folds away after a while, hovering the notch brings it back
    private func scheduleParking() {
        parkTask?.cancel()
        let delay = timing.unattended
        let recheck = timing.parkRecheck
        parkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            while let self, !Task.isCancelled, self.pointerIsOverIsland() {
                try? await Task.sleep(for: .seconds(recheck))
            }
            guard let self, !Task.isCancelled, self.status?.kind == .signIn else { return }
            print("banner unattended, parking")
            self.parked = true
            self.collapse()
            self.parkTask = nil
        }
    }
}

enum NotificationType {
    case success
    case error
}
