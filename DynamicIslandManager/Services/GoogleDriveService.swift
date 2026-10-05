import Foundation
import AppKit
import GoogleSignIn
import GTMAppAuth
import AppAuthCore

// where drive access tokens come from, swapped for a fake in tests
protocol DriveTokenSource {
    func accessToken() async throws -> String
    func forceRefresh() async throws -> String
}

// the bits of drive the island needs, swapped for a fake in tests
protocol DriveUploading: AnyObject {
    func uploadFile(_ fileItem: FileItem, to parentId: String?) async throws -> DriveFile
    func deleteFile(id: String, protectedIds: Set<String>) async throws
}

class GoogleDriveService: ObservableObject, DriveUploading {
    @Published var isSignedIn = false
    @Published var userEmail: String?

    // drive.file only sees files the app made or the user picked in google picker,
    // keeps us out of google's restricted scope review
    static let driveScope = "https://www.googleapis.com/auth/drive.file"
    private let scopes = [GoogleDriveService.driveScope]

    var transport: DriveTransport
    // nil means google sign-in
    var tokenSource: DriveTokenSource?
    // --bad-token: send "Bearer invalid" once to exercise the 401 path
    var sendBadTokenOnce = false

    init(transport: DriveTransport = URLSessionDriveTransport(), tokenSource: DriveTokenSource? = nil) {
        self.transport = transport
        self.tokenSource = tokenSource
        guard tokenSource == nil else { return }

        // setup google signin
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String {
            let config = GIDConfiguration(clientID: clientID)
            GIDSignIn.sharedInstance.configuration = config
        }
    }

    @MainActor
    func signIn(presenting window: NSWindow) async throws {
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: window,
            hint: nil,
            additionalScopes: scopes
        )

        // google's consent screen lets people untick drive; without it every drive call fails
        guard result.user.grantedScopes?.contains(Self.driveScope) == true else {
            throw DriveError(category: .authExpired, reason: "driveScopeNotGranted",
                             message: "Google Drive access wasn't allowed. Sign in again and tick the Google Drive box.")
        }

        isSignedIn = true
        userEmail = result.user.profile?.email
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        userEmail = nil
    }

    // google sign-in and appauth deliver on main and keep unlocked state, so they're only touched on main
    @MainActor
    func restorePreviousSignIn() async throws {
        let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        // a saved session without drive access can't do anything: show the sign-in window instead
        guard user.grantedScopes?.contains(Self.driveScope) == true else {
            throw DriveError(category: .authExpired, reason: "driveScopeNotGranted",
                             message: "Google Drive access wasn't allowed. Sign in again and tick the Google Drive box.")
        }
        isSignedIn = true
        userEmail = user.profile?.email
    }

    // MARK: drive calls

    private static let filesURL = "https://www.googleapis.com/drive/v3/files"

    // upload into a folder (nil = my drive root), returns the new file with its parents
    @discardableResult
    func uploadFile(_ fileItem: FileItem, to parentId: String? = nil) async throws -> DriveFile {
        if let parentId, !isValidDriveId(parentId) {
            throw DriveError.refused("not a drive folder id: \(parentId)")
        }

        let mimeType = DriveMime.forExtension(fileItem.fileExtension)
        var metadata: [String: Any] = ["name": fileItem.name]
        if let mimeType {
            metadata["mimeType"] = mimeType
        }
        if let parentId {
            metadata["parents"] = [parentId]
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        do {
            try MultipartUpload.writeBody(metadata: metadata, fileURL: fileItem.url,
                                          mimeType: mimeType ?? "application/octet-stream",
                                          boundary: boundary, to: bodyURL)
        } catch MultipartUpload.Failure.unreadable(let error) {
            print("couldn't read \(fileItem.name): \(error.localizedDescription)")
            throw DriveError(category: .other, reason: "readFailed", message: "Couldn't read \(fileItem.name)")
        } catch {
            print("couldn't prepare \(fileItem.name): \(error.localizedDescription)")
            if DriveError.isDiskFull(error) {
                throw DriveError(category: .other, reason: "diskFull", message: "Not enough disk space to prepare the upload")
            }
            throw DriveError(category: .other, reason: "prepareFailed", message: "Couldn't prepare the upload")
        }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,parents,mimeType")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        print("uploading: \(fileItem.name) to \(parentId ?? "my drive")")
        let data = try await send(request, bodyFile: bodyURL)
        let file = try decode(DriveFile.self, from: data)
        print("upload done: \(file.id)")
        return file
    }

    func getFile(id: String, fields: String = "id,name,parents,mimeType") async throws -> DriveFile {
        guard isValidDriveId(id) else { throw DriveError.refused("not a drive file id: \(id)") }
        var components = URLComponents(string: "\(Self.filesURL)/\(id)")!
        components.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let data = try await send(URLRequest(url: components.url!))
        return try decode(DriveFile.self, from: data)
    }

    // only ever deletes our own uploads (undo): never a folder, never a destination
    func deleteFile(id: String, protectedIds: Set<String>) async throws {
        guard isValidDriveId(id) else { throw DriveError.refused("not a drive file id: \(id)") }
        guard !protectedIds.contains(id) else {
            throw DriveError.refused("\(id) is a destination folder, not deleting it")
        }
        let file = try await getFile(id: id, fields: "id,name,mimeType")
        guard file.mimeType != DriveMime.folder else {
            throw DriveError.refused("\(id) is a folder, not deleting it")
        }

        // permanent delete, skips the trash
        var request = URLRequest(url: URL(string: "\(Self.filesURL)/\(id)")!)
        request.httpMethod = "DELETE"
        _ = try await send(request)
        print("deleted: \(id)")
    }

    // under drive.file this only lists files the app made
    func listFolder(id: String) async throws -> [DriveFile] {
        guard isValidDriveId(id) else { throw DriveError.refused("not a drive folder id: \(id)") }
        var components = URLComponents(string: Self.filesURL)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "'\(id)' in parents and trashed=false"),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,parents)"),
            URLQueryItem(name: "pageSize", value: "100")
        ]
        let data = try await send(URLRequest(url: components.url!))
        struct Listing: Decodable { let files: [DriveFile] }
        return try decode(Listing.self, from: data).files
    }

    func createFolder(named name: String, in parentId: String) async throws -> DriveFolder {
        var request = URLRequest(url: URL(string: "\(Self.filesURL)?fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": DriveMime.folder,
            "parents": [parentId]
        ])

        let data = try await send(request)
        return try decode(DriveFolder.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DriveError(category: .other, reason: "badResponse", message: "Drive sent something unexpected")
        }
    }

    // MARK: tokens

    func freshAccessToken() async throws -> String {
        do {
            if let tokenSource {
                return try await tokenSource.accessToken()
            }
            return try await googleAccessToken()
        } catch {
            throw DriveError.from(error)
        }
    }

    private func forceRefreshAccessToken() async throws -> String {
        do {
            if let tokenSource {
                return try await tokenSource.forceRefresh()
            }
            return try await forceRefreshGoogleToken()
        } catch {
            throw DriveError.from(error)
        }
    }

    @MainActor
    private func googleAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw DriveError.notSignedIn
        }
        return try await user.refreshTokensIfNeeded().accessToken.tokenString
    }

    // google sign-in has no public force refresh, so go through its appauth session
    @MainActor
    private func forceRefreshGoogleToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw DriveError.notSignedIn
        }
        // internals changed, treat the 401 as signed out
        guard let session = user.fetcherAuthorizer as? AuthSession else {
            throw DriveError(category: .authExpired, reason: "noAuthSession", message: "Couldn't refresh the sign-in")
        }
        let oldResponse = session.authState.lastTokenResponse
        session.authState.setNeedsTokenRefresh()
        let token: String = try await withCheckedThrowingContinuation { continuation in
            session.authState.performAction { token, _, error in
                continuation.resume(with: Self.resolveRefresh(token: token, error: error))
            }
        }
        // never the token itself: a new response object proves google answered the refresh
        // (google may hand back the same still-valid token, so the expiry can stay put)
        let newResponse = session.authState.lastTokenResponse
        print("drive: refresh round trip: new token response \(newResponse !== oldResponse ? "yes" : "no"), "
              + "expiry \(Self.clock(oldResponse?.accessTokenExpirationDate)) -> \(Self.clock(newResponse?.accessTokenExpirationDate))")
        return token
    }

    // appauth hands back the OLD token together with a transient error (timeouts, 5xx),
    // so the error has to win, or the retry would send the token drive just rejected
    static func resolveRefresh(token: String?, error: Error?) -> Result<String, Error> {
        if let error {
            return .failure(DriveError.from(error))
        }
        if let token {
            return .success(token)
        }
        return .failure(DriveError(category: .authExpired, reason: "noToken", message: "Refresh gave no token"))
    }

    private static func clock(_ date: Date?) -> String {
        guard let date else { return "?" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // every drive call goes through here: fresh token, one forced refresh and retry on 401
    private func send(_ request: URLRequest, bodyFile: URL? = nil) async throws -> Data {
        var token = try await freshAccessToken()
        if sendBadTokenOnce {
            sendBadTokenOnce = false
            token = "invalid"
            print("drive: sending a bad token first (--bad-token)")
        }

        var (data, response) = try await perform(request, token: token, bodyFile: bodyFile)
        if response.statusCode == 401 {
            print("drive: 401, forcing a token refresh")
            let refreshed = try await forceRefreshAccessToken()
            print("drive: token refreshed, retrying once")
            (data, response) = try await perform(request, token: refreshed, bodyFile: bodyFile)
        }

        guard (200..<300).contains(response.statusCode) else {
            let error = DriveError.http(status: response.statusCode, body: data)
            print("drive request failed: \(error.localizedDescription)")
            throw error
        }
        return data
    }

    private func perform(_ request: URLRequest, token: String, bodyFile: URL?) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.send(request, bodyFile: bodyFile)
        } catch {
            throw DriveError.from(error)
        }
    }
}
