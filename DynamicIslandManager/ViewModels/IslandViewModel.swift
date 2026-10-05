import SwiftUI
import Combine

class IslandViewModel: ObservableObject {
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
    @Published var uploadStatus: String?
    @Published var showNotification: Bool = false
    @Published var notificationMessage: String = ""
    @Published var notificationType: NotificationType = .success

    let driveService: GoogleDriveService

    init(driveService: GoogleDriveService = GoogleDriveService()) {
        self.driveService = driveService
    }

    // expand collapse
    func expand() {
        withAnimation(AnimationConstants.expand) {
            currentState = .expanded
        }
    }

    func collapse() {
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

    func handleUploadDrop(urls: [URL]) async {
        print("handling upload drop of \(urls.count) file(s)")
        let fileItems = urls.map { url in
            FileItem(url: url)
        }

        // zip if multiple
        if fileItems.count > 1 {
            print("zipping \(fileItems.count) files...")
            await MainActor.run {
                uploadStatus = "Zipping \(fileItems.count) files..."
            }

            do {
                let zipURL = try ZipUtility.zipFiles(fileItems)
                let zipFileItem = FileItem(url: zipURL)
                await uploadFile(zipFileItem)
                ZipUtility.cleanupTempFile(at: zipURL)
            } catch {
                await showNotificationMessage("Failed to zip files: \(error.localizedDescription)", type: .error)
                await MainActor.run {
                    uploadStatus = nil
                }
            }
        } else {
            // single file
            for fileItem in fileItems {
                await uploadFile(fileItem)
            }
        }
    }

    func uploadFile(_ fileItem: FileItem) async {
        guard driveService.isSignedIn else {
            await showNotificationMessage("Please sign in to Google Drive first", type: .error)
            return
        }

        await MainActor.run {
            uploadStatus = "Uploading \(fileItem.name)..."
        }

        do {
            try await driveService.uploadFile(fileItem)
            await showNotificationMessage("Uploaded: \(fileItem.name)", type: .success)
            await MainActor.run {
                uploadStatus = nil
            }
        } catch {
            await showNotificationMessage("Failed to upload: \(fileItem.name)", type: .error)
            await MainActor.run {
                uploadStatus = nil
            }
            print("upload error: \(error.localizedDescription)")
        }
    }

    func showNotificationMessage(_ message: String, type: NotificationType) async {
        await MainActor.run {
            notificationMessage = message
            notificationType = type
            showNotification = true
        }

        // auto dismiss
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            showNotification = false
        }
    }
}

enum NotificationType {
    case success
    case error
}
