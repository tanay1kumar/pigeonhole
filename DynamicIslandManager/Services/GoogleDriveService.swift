import Foundation
import GoogleSignIn

class GoogleDriveService: ObservableObject {
    @Published var isSignedIn = false
    @Published var userEmail: String?
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0.0
    @Published var lastUploadError: String?

    // drive.file only sees files the app made or the user picked in google picker,
    // keeps us out of google's restricted scope review
    private let scopes = ["https://www.googleapis.com/auth/drive.file"]

    init() {
        // setup google signin
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String {
            let config = GIDConfiguration(clientID: clientID)
            GIDSignIn.sharedInstance.configuration = config
        }
    }

    func signIn() async throws {
        guard let presentingWindow = NSApplication.shared.windows.first else {
            throw GoogleDriveError.noPresentingWindow
        }

        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presentingWindow,
            hint: nil,
            additionalScopes: scopes
        )

        await MainActor.run {
            self.isSignedIn = true
            self.userEmail = result.user.profile?.email
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        userEmail = nil
    }

    func restorePreviousSignIn() async throws {
        let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()

        await MainActor.run {
            self.isSignedIn = true
            self.userEmail = user.profile?.email
        }
    }

    // upload file to drive
    func uploadFile(_ fileItem: FileItem) async throws {
        guard isSignedIn else {
            throw GoogleDriveError.notSignedIn
        }

        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GoogleDriveError.notSignedIn
        }

        await MainActor.run {
            self.isUploading = true
            self.uploadProgress = 0.0
            self.lastUploadError = nil
        }

        print("uploading: \(fileItem.name)")

        do {
            let accessToken = user.accessToken.tokenString
            let fileData = try Data(contentsOf: fileItem.url)

            let metadata: [String: Any] = [
                "name": fileItem.name,
                "mimeType": mimeType(for: fileItem.fileExtension)
            ]

            let metadataData = try JSONSerialization.data(withJSONObject: metadata)

            // build multipart request
            let boundary = "Boundary-\(UUID().uuidString)"
            var body = Data()

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
            body.append(metadataData)
            body.append("\r\n".data(using: .utf8)!)

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType(for: fileItem.fileExtension))\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
            request.httpBody = body

            await MainActor.run {
                self.uploadProgress = 0.5
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GoogleDriveError.uploadFailed("Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("upload failed: \(httpResponse.statusCode) - \(errorMessage)")
                throw GoogleDriveError.uploadFailed("HTTP \(httpResponse.statusCode)")
            }

            // parse response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fileId = json["id"] as? String {
                print("upload successful, file id: \(fileId)")
            }

            await MainActor.run {
                self.uploadProgress = 1.0
                self.isUploading = false
            }

            print("upload done: \(fileItem.name)")

        } catch {
            await MainActor.run {
                self.isUploading = false
                self.uploadProgress = 0.0
                self.lastUploadError = error.localizedDescription
            }
            print("upload error: \(error.localizedDescription)")
            throw error
        }
    }

    func createFolder(named name: String, in parentId: String) async throws -> DriveFolder {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": Self.folderMimeType,
            "parents": [parentId]
        ])

        let data = try await authorizedRequest(request)
        return try JSONDecoder().decode(DriveFolder.self, from: data)
    }

    private static let folderMimeType = "application/vnd.google-apps.folder"

    func freshAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GoogleDriveError.notSignedIn
        }
        return try await user.refreshTokensIfNeeded().accessToken.tokenString
    }

    // adds a fresh access token and checks the status code
    private func authorizedRequest(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await freshAccessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("drive request failed: \(status) - \(String(data: data, encoding: .utf8) ?? "")")
            throw GoogleDriveError.requestFailed("HTTP \(status)")
        }
        return data
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}

enum GoogleDriveError: LocalizedError {
    case noPresentingWindow
    case notSignedIn
    case uploadFailed(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPresentingWindow:
            return "No window available to present sign-in"
        case .notSignedIn:
            return "User is not signed in"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .requestFailed(let message):
            return "Google Drive request failed: \(message)"
        }
    }
}
