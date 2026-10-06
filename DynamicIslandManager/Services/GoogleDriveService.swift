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
protocol DriveClient: AnyObject {
    // progress is the share of the file drive has, 0 to 1
    func uploadFile(_ fileItem: FileItem, to parentId: String?, progress: (@Sendable (Double) -> Void)?) async throws -> DriveFile
    func deleteFile(id: String, protectedIds: Set<String>) async throws
    func about() async throws -> DriveAbout
}

extension DriveClient {
    func uploadFile(_ fileItem: FileItem, to parentId: String?) async throws -> DriveFile {
        try await uploadFile(fileItem, to: parentId, progress: nil)
    }
}

class GoogleDriveService: ObservableObject, DriveClient {
    @Published var isSignedIn = false
    @Published var userEmail: String?

    // drive.file only sees files the app made or the user picked in google picker,
    // keeps us out of google's restricted scope review
    static let driveScope = "https://www.googleapis.com/auth/drive.file"
    private let scopes = [GoogleDriveService.driveScope]

    var transport: DriveTransport
    // nil means google sign-in
    var tokenSource: DriveTokenSource?
    // --bad-token sends "Bearer invalid" once to test the 401 path
    var sendBadTokenOnce = false
    // --resumable sends small files the resumable way too
    var forceResumable = false
    // waits before asking a resumable upload where it got to, tests shorten them
    var resumableRetryDelays = ResumableUpload.retryDelays
    #if DEBUG
    // --drop-after-chunk n, the connection drops once after n chunks
    var dropAfterChunk: Int?
    #endif

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

        // people can untick drive on google's consent screen, then every drive call fails
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

    // google sign-in and appauth call back on main and aren't thread safe, main only
    @MainActor
    func restorePreviousSignIn() async throws {
        let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        // saved session without drive access is useless, show the sign-in window
        guard user.grantedScopes?.contains(Self.driveScope) == true else {
            throw DriveError(category: .authExpired, reason: "driveScopeNotGranted",
                             message: "Google Drive access wasn't allowed. Sign in again and tick the Google Drive box.")
        }
        isSignedIn = true
        userEmail = user.profile?.email
    }

    // MARK: drive calls

    private static let filesURL = "https://www.googleapis.com/drive/v3/files"
    // what comes back for an upload, the link and size are for copy link and activity
    static let uploadFields = "id,name,parents,mimeType,webViewLink,size"

    // upload into a folder (nil = my drive root), returns the new file with its parents
    // files over 5 MB go resumable in chunks, smaller ones in one multipart request
    @discardableResult
    func uploadFile(_ fileItem: FileItem, to parentId: String? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> DriveFile {
        if let parentId, !isValidDriveId(parentId) {
            throw DriveError.refused("not a drive folder id: \(parentId)")
        }
        if fileItem.size > 0 && (forceResumable || ResumableUpload.shouldUse(size: fileItem.size)) {
            return try await resumableUpload(fileItem, to: parentId, progress: progress)
        }
        let file = try await multipartUpload(fileItem, to: parentId, progress: progress)
        progress?(1)
        return file
    }

    private func metadata(for fileItem: FileItem, parentId: String?) -> (fields: [String: Any], mimeType: String?) {
        let mimeType = DriveMime.forExtension(fileItem.fileExtension)
        var fields: [String: Any] = ["name": fileItem.name]
        if let mimeType {
            fields["mimeType"] = mimeType
        }
        if let parentId {
            fields["parents"] = [parentId]
        }
        return (fields, mimeType)
    }

    private func multipartUpload(_ fileItem: FileItem, to parentId: String?, progress: (@Sendable (Double) -> Void)?) async throws -> DriveFile {
        let (fields, mimeType) = metadata(for: fileItem, parentId: parentId)
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        do {
            try MultipartUpload.writeBody(metadata: fields, fileURL: fileItem.url,
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

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=\(Self.uploadFields)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        print("uploading: \(fileItem.name) to \(parentId ?? "my drive")")
        // all of the body out is 1, drive is finishing the file then, as on the resumable path
        let bodySize = (try? FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? Int64) ?? 0
        let data = try await send(request, body: .file(bodyURL, progress: { sent in
            guard bodySize > 0 else { return }
            progress?(min(1, Double(sent) / Double(bodySize)))
        }))
        let file = try decode(DriveFile.self, from: data)
        print("upload done: \(file.id)")
        return file
    }

    // MARK: resumable

    private func resumableUpload(_ fileItem: FileItem, to parentId: String?, progress: (@Sendable (Double) -> Void)?) async throws -> DriveFile {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileItem.url)
        } catch {
            print("couldn't read \(fileItem.name): \(error.localizedDescription)")
            throw DriveError(category: .other, reason: "readFailed", message: "Couldn't read \(fileItem.name)")
        }
        defer { try? handle.close() }
        // the size on disk now, not when the file was dropped
        let total = Int64((try? handle.seekToEnd()) ?? UInt64(fileItem.size))
        var restarted = false
        while true {
            let session = try await startResumableSession(fileItem, to: parentId, total: total)
            do {
                let file = try await sendChunks(handle, name: fileItem.name, session: session, total: total, progress: progress)
                print("upload done: \(file.id)")
                return file
            } catch let error as DriveError where error.reason == ResumableUpload.expiredReason && !restarted {
                // sessions last about a week, start over once
                restarted = true
                print("resumable: the session expired, starting over")
            }
        }
    }

    private func startResumableSession(_ fileItem: FileItem, to parentId: String?, total: Int64) async throws -> URL {
        let (fields, mimeType) = metadata(for: fileItem, parentId: parentId)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=\(Self.uploadFields)")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType ?? "application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let (data, response) = try await sendRaw(request)
        guard (200..<300).contains(response.statusCode) else {
            let error = DriveError.http(status: response.statusCode, body: data)
            print("drive request failed: \(error.localizedDescription)")
            throw error
        }
        guard let location = response.value(forHTTPHeaderField: "Location"), let session = URL(string: location),
              session.scheme == "https" else {
            throw DriveError(category: .other, reason: "badResponse", message: "Drive didn't start the upload")
        }
        print("uploading: \(fileItem.name) to \(parentId ?? "my drive"), resumable, \(total) bytes")
        return session
    }

    // 8 MiB at a time from where drive says it got to
    // 5xx or offline, wait and ask where it got to, then go on from there
    private func sendChunks(_ handle: FileHandle, name: String, session: URL, total: Int64,
                            progress: (@Sendable (Double) -> Void)?) async throws -> DriveFile {
        var offset: Int64 = 0
        var confirmed: Int64 = 0    // the most drive has said it has
        var tries = 0
        var askWhere = false
        var chunks = 0
        while true {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: session)
                request.httpMethod = "PUT"
                let response: (Data, HTTPURLResponse)
                let asked = askWhere
                if askWhere {
                    askWhere = false
                    request.setValue(ResumableUpload.contentRange(start: 0, length: 0, total: total), forHTTPHeaderField: "Content-Range")
                    response = try await sendRaw(request, body: .data(Data(), progress: nil))
                    print("resumable: asked where it got to, \(response.1.statusCode) \(response.1.value(forHTTPHeaderField: "Range") ?? "nothing yet")")
                } else {
                    let expected = Int(min(Int64(ResumableUpload.chunkSize), total - offset))
                    let chunk: Data
                    do {
                        try handle.seek(toOffset: UInt64(offset))
                        chunk = try handle.read(upToCount: expected) ?? Data()
                    } catch {
                        // a disk pulled mid-upload is the file's problem, not drive's
                        print("couldn't read \(name): \(error.localizedDescription)")
                        throw DriveError(category: .other, reason: "readFailed", message: "Couldn't read \(name)")
                    }
                    // the file got shorter since it started, a short chunk would never finish
                    guard chunk.count == expected else {
                        throw DriveError(category: .other, reason: "readFailed", message: "\(name) changed while uploading")
                    }
                    request.setValue(ResumableUpload.contentRange(start: offset, length: chunk.count, total: total), forHTTPHeaderField: "Content-Range")
                    #if DEBUG
                    if let drop = dropAfterChunk, chunks == drop {
                        dropAfterChunk = nil
                        print("resumable: dropping the connection after chunk \(chunks) (--drop-after-chunk)")
                        throw URLError(.networkConnectionLost)
                    }
                    #endif
                    let start = offset
                    response = try await sendRaw(request, body: .data(chunk, progress: { sent in
                        progress?(Double(start + sent) / Double(total))
                    }))
                    chunks += 1
                }
                if let file = try resumableResult(response.0, response.1, offset: &offset, total: total) {
                    progress?(1)
                    return file
                }
                // a chunk that went through, or drive holding more than it ever said, counts as recovered
                // a question that shows nothing new doesn't, so a chunk that keeps failing still gives up
                if !asked || offset > confirmed {
                    tries = 0
                }
                confirmed = max(confirmed, offset)
                progress?(Double(offset) / Double(total))
                print(String(format: "resumable: %@ %.0f%%", name, Double(offset) / Double(total) * 100))
            } catch let error where Self.canResume(error) && tries < resumableRetryDelays.count {
                let delay = resumableRetryDelays[tries]
                tries += 1
                print("resumable: \(DriveError.from(error).localizedDescription), asking where it got to in \(delay) s")
                try await Task.sleep(for: .seconds(delay))
                askWhere = true
            }
        }
    }

    // 200 or 201 done, 308 go on from its range, 404 or 410 the session is gone
    private func resumableResult(_ data: Data, _ response: HTTPURLResponse, offset: inout Int64, total: Int64) throws -> DriveFile? {
        switch response.statusCode {
        case 200, 201:
            return try decode(DriveFile.self, from: data)
        case 308:
            guard let next = ResumableUpload.nextOffset(rangeHeader: response.value(forHTTPHeaderField: "Range")),
                  next >= 0, next <= total else {
                throw DriveError(category: .other, reason: "badResponse", message: "Drive sent something unexpected")
            }
            offset = next
            return nil
        case 404, 410:
            throw DriveError(category: .notFound, status: response.statusCode, reason: ResumableUpload.expiredReason,
                             message: "The upload session expired")
        default:
            let error = DriveError.http(status: response.statusCode, body: data)
            print("drive request failed: \(error.localizedDescription)")
            throw error
        }
    }

    // a server error or no connection, the bytes drive kept are still there
    private static func canResume(_ error: Error) -> Bool {
        let category = DriveError.from(error).category
        return category == .server || category == .offline
    }

    func about() async throws -> DriveAbout {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/about")!
        components.queryItems = [URLQueryItem(name: "fields", value: "storageQuota,user(emailAddress,displayName)")]
        let data = try await send(URLRequest(url: components.url!))
        return try decode(DriveAbout.self, from: data)
    }

    func getFile(id: String, fields: String = "id,name,parents,mimeType") async throws -> DriveFile {
        guard isValidDriveId(id) else { throw DriveError.refused("not a drive file id: \(id)") }
        var components = URLComponents(string: "\(Self.filesURL)/\(id)")!
        components.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let data = try await send(URLRequest(url: components.url!))
        return try decode(DriveFile.self, from: data)
    }

    // only for deleting our own uploads (undo), never folders or destinations
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
        // compare response objects, not tokens, google can hand back the same token
        let newResponse = session.authState.lastTokenResponse
        print("drive: refresh round trip: new token response \(newResponse !== oldResponse ? "yes" : "no"), "
              + "expiry \(Self.clock(oldResponse?.accessTokenExpirationDate)) -> \(Self.clock(newResponse?.accessTokenExpirationDate))")
        return token
    }

    // appauth returns the old token along with transient errors (timeouts, 5xx)
    // so the error wins, otherwise the retry sends the token drive just rejected
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

    // what a request carries, a chunk reports how much of it went out
    private enum Body {
        case none
        case file(URL, progress: (@Sendable (Int64) -> Void)?)
        case data(Data, progress: (@Sendable (Int64) -> Void)?)
    }

    // every drive call goes through here, 2xx or a DriveError
    private func send(_ request: URLRequest, body: Body = .none) async throws -> Data {
        let (data, response) = try await sendRaw(request, body: body)
        guard (200..<300).contains(response.statusCode) else {
            let error = DriveError.http(status: response.statusCode, body: data)
            print("drive request failed: \(error.localizedDescription)")
            throw error
        }
        return data
    }

    // fresh token and one refresh + retry on 401, any other status is the caller's
    private func sendRaw(_ request: URLRequest, body: Body = .none) async throws -> (Data, HTTPURLResponse) {
        var token = try await freshAccessToken()
        if sendBadTokenOnce {
            sendBadTokenOnce = false
            token = "invalid"
            print("drive: sending a bad token first (--bad-token)")
        }

        var (data, response) = try await perform(request, token: token, body: body)
        if response.statusCode == 401 {
            print("drive: 401, forcing a token refresh")
            let refreshed = try await forceRefreshAccessToken()
            print("drive: token refreshed, retrying once")
            (data, response) = try await perform(request, token: refreshed, body: body)
        }
        return (data, response)
    }

    private func perform(_ request: URLRequest, token: String, body: Body) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            switch body {
            case .none:
                return try await transport.send(request, bodyFile: nil)
            case .file(let url, let progress):
                return try await transport.send(request, bodyFile: url, progress: progress)
            case .data(let data, let progress):
                return try await transport.send(request, body: data, progress: progress)
            }
        } catch {
            throw DriveError.from(error)
        }
    }
}
