#if DEBUG
import Foundation
import GoogleSignIn

// MARK: fakes

// records every request and answers from a handler, never touches the network
final class FakeDriveTransport: DriveTransport {
    struct Sent {
        let request: URLRequest
        let body: Data?
        var authorization: String? { request.value(forHTTPHeaderField: "Authorization") }
        var method: String { request.httpMethod ?? "GET" }
    }

    private let lock = NSLock()
    private var log: [Sent] = []
    var handler: (URLRequest) throws -> (Int, Data)

    init(handler: @escaping (URLRequest) throws -> (Int, Data)) {
        self.handler = handler
    }

    var sent: [Sent] {
        lock.withLock { log }
    }

    func send(_ request: URLRequest, bodyFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let body = try bodyFile.map { try Data(contentsOf: $0) } ?? request.httpBody
        lock.withLock {
            log.append(Sent(request: request, body: body))
        }
        let (status, data) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class FakeTokens: DriveTokenSource {
    var token = "t1"
    var refreshedToken = "t2"
    var accessError: Error?
    var refreshError: Error?
    private(set) var refreshCount = 0

    func accessToken() async throws -> String {
        if let accessError { throw accessError }
        return token
    }

    func forceRefresh() async throws -> String {
        refreshCount += 1
        if let refreshError { throw refreshError }
        return refreshedToken
    }
}

enum DriveTestSupport {
    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func fileJSON(id: String = "F1", name: String = "file", parents: [String]? = nil, mime: String? = nil) -> Data {
        var object: [String: Any] = ["id": id, "name": name]
        if let parents { object["parents"] = parents }
        if let mime { object["mimeType"] = mime }
        return json(object)
    }

    static func driveErrorBody(_ code: Int, reason: String, message: String = "nope") -> Data {
        json(["error": ["code": code, "message": message, "errors": [["reason": reason, "message": message]]]])
    }

    static func makeFile(in directory: URL, named name: String, contents: Data = Data("hello".utf8)) throws -> FileItem {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return FileItem(url: url)
    }

    // splits the fixed two-part multipart/related body
    static func parseMultipart(_ body: Data, boundary: String) -> (metadata: [String: Any], mediaType: String, media: Data)? {
        let delimiter = Data("--\(boundary)\r\n".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        let middle = Data("\r\n--\(boundary)\r\n".utf8)
        let closing = Data("\r\n--\(boundary)--\r\n".utf8)
        guard body.starts(with: delimiter),
              let firstHeaders = body.range(of: headerEnd),
              let middleRange = body.range(of: middle, in: firstHeaders.upperBound..<body.endIndex),
              let secondHeaders = body.range(of: headerEnd, in: middleRange.upperBound..<body.endIndex),
              let closingRange = body.range(of: closing, options: .backwards),
              closingRange.upperBound == body.endIndex else { return nil }
        let metadataData = body.subdata(in: firstHeaders.upperBound..<middleRange.lowerBound)
        let mediaHeaders = String(decoding: body.subdata(in: middleRange.upperBound..<secondHeaders.lowerBound), as: UTF8.self)
        guard let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              mediaHeaders.hasPrefix("Content-Type: ") else { return nil }
        let media = body.subdata(in: secondHeaders.upperBound..<closingRange.lowerBound)
        return (metadata, String(mediaHeaders.dropFirst("Content-Type: ".count)), media)
    }

    static func boundary(of request: URLRequest) -> String? {
        guard let type = request.value(forHTTPHeaderField: "Content-Type"),
              let range = type.range(of: "boundary=") else { return nil }
        return String(type[range.upperBound...])
    }

    static func uploadTempFiles() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return items.filter { $0.hasPrefix("upload-") && $0.hasSuffix(".multipart") }
    }
}

// MARK: error mapping

enum DriveErrorTests: TestSuite {
    static let name = "DriveError"

    static var tests: [TestCase] {
        [
            TestCase("http status categories") { t in
                let empty = Data()
                t.expectEqual(DriveError.http(status: 401, body: empty).category, .authExpired)
                t.expectEqual(DriveError.http(status: 403, body: DriveTestSupport.driveErrorBody(403, reason: "insufficientFilePermissions")).category, .permission)
                t.expectEqual(DriveError.http(status: 403, body: DriveTestSupport.driveErrorBody(403, reason: "appNotAuthorizedToFile")).category, .permission)
                t.expectEqual(DriveError.http(status: 403, body: DriveTestSupport.driveErrorBody(403, reason: "rateLimitExceeded")).category, .server)
                t.expectEqual(DriveError.http(status: 403, body: DriveTestSupport.driveErrorBody(403, reason: "userRateLimitExceeded")).category, .server)
                t.expectEqual(DriveError.http(status: 403, body: DriveTestSupport.driveErrorBody(403, reason: "storageQuotaExceeded")).category, .other)
                t.expectEqual(DriveError.http(status: 403, body: empty).category, .permission)
                t.expectEqual(DriveError.http(status: 404, body: empty).category, .notFound)
                t.expectEqual(DriveError.http(status: 429, body: empty).category, .server)
                t.expectEqual(DriveError.http(status: 500, body: empty).category, .server)
                t.expectEqual(DriveError.http(status: 503, body: empty).category, .server)
                t.expectEqual(DriveError.http(status: 400, body: empty).category, .other)
                t.expectEqual(DriveError.http(status: 409, body: empty).status, 409)
            },
            TestCase("parses drive's json error body") { t in
                let body = DriveTestSupport.json(["error": ["code": 403, "message": "The user does not have sufficient permissions for file X.",
                                                           "errors": [["domain": "global", "reason": "insufficientFilePermissions", "message": "inner"]]]])
                let error = DriveError.http(status: 403, body: body)
                t.expectEqual(error.reason, "insufficientFilePermissions")
                t.expectEqual(error.message, "The user does not have sufficient permissions for file X.")
                t.expectEqual(error.status, 403)

                // newer bodies may only carry "status"
                let statusOnly = DriveError.parseBody(DriveTestSupport.json(["error": ["code": 401, "message": "Request had invalid authentication credentials.", "status": "UNAUTHENTICATED"]]))
                t.expectEqual(statusOnly.reason, "UNAUTHENTICATED")
                t.expectEqual(statusOnly.message, "Request had invalid authentication credentials.")

                // html or text from a proxy
                let html = DriveError.parseBody(Data("<html>Bad Gateway</html>".utf8))
                t.expectEqual(html.reason, nil)
                t.expectEqual(html.message, "<html>Bad Gateway</html>")

                let empty = DriveError.parseBody(Data())
                t.expectEqual(empty.reason, nil)
                t.expectEqual(empty.message, nil)

                // json but not an error object
                let other = DriveError.parseBody(DriveTestSupport.json(["files": []]))
                t.expectEqual(other.reason, nil)
            },
            TestCase("maps urlsession, appauth and sign-in errors") { t in
                t.expectEqual(DriveError.from(URLError(.notConnectedToInternet)).category, .offline)
                t.expectEqual(DriveError.from(URLError(.timedOut)).category, .offline)
                t.expectEqual(DriveError.from(URLError(.networkConnectionLost)).category, .offline)
                t.expectEqual(DriveError.from(URLError(.cancelled)).category, .other)

                // appauth wraps network failures during a refresh
                let wrapped = NSError(domain: "org.openid.appauth.general", code: -5,
                                      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)])
                t.expectEqual(DriveError.from(wrapped).category, .offline)

                // dead refresh token
                let invalidGrant = NSError(domain: "org.openid.appauth.oauth_token", code: -10)
                t.expectEqual(DriveError.from(invalidGrant).category, .authExpired)

                let gid = NSError(domain: "com.google.GIDSignIn", code: -4)
                t.expectEqual(DriveError.from(gid).category, .authExpired)

                t.expectEqual(DriveError.from(CancellationError()).reason, "cancelled")

                let original = DriveError(category: .permission, status: 403, reason: "x")
                t.expectEqual(DriveError.from(original), original)

                let random = NSError(domain: NSCocoaErrorDomain, code: 4)
                t.expectEqual(DriveError.from(random).category, .other)
            },
            TestCase("short text for the island") { t in
                t.expectEqual(DriveError(category: .authExpired).shortText, "Signed out — Sign in again")
                t.expectEqual(DriveError(category: .permission, status: 403).shortText, "No access to that folder")
                t.expectEqual(DriveError(category: .offline).shortText, "You're offline")
                t.expectEqual(DriveError(category: .server, status: 503).shortText, "Drive error (503), retry")
                t.expectEqual(DriveError(category: .server, status: 429).shortText, "Drive is busy, retry")
                t.expectEqual(DriveError(category: .other, status: 403, reason: "storageQuotaExceeded").shortText, "Your Drive is full")
                t.expectEqual(DriveError(category: .other, status: 400).shortText, "Drive error (400)")
                t.expect(!DriveError(category: .notFound, status: 404).shortText.isEmpty)
                t.expect(DriveError(category: .server, status: 500, reason: "backendError", message: "m").localizedDescription.contains("HTTP 500"))
            },
            TestCase("missing drive scope is a sign-in problem, not a folder one") { t in
                let legacy = DriveTestSupport.json(["error": ["code": 403, "message": "Request had insufficient authentication scopes.",
                                                              "errors": [["reason": "insufficientPermissions", "message": "Insufficient Permission"]],
                                                              "status": "PERMISSION_DENIED"]])
                t.expectEqual(DriveError.http(status: 403, body: legacy).category, .authExpired)
                let modern = DriveTestSupport.json(["error": ["code": 403, "message": "Request had insufficient authentication scopes.",
                                                              "status": "PERMISSION_DENIED",
                                                              "details": [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]]]])
                t.expectEqual(DriveError.http(status: 403, body: modern).category, .authExpired)
                t.expectEqual(DriveError.http(status: 403, body: modern).reason, "ACCESS_TOKEN_SCOPE_INSUFFICIENT")
                // plain no-access stays a permission error
                let noAccess = DriveTestSupport.json(["error": ["code": 403, "message": "no", "status": "PERMISSION_DENIED"]])
                t.expectEqual(DriveError.http(status: 403, body: noAccess).category, .permission)
            },
            TestCase("forced refresh: an error beats the stale token appauth hands back") { t in
                // transient failure: appauth calls back with the OLD token and its network error (-5 wrapping urlsession's)
                let transient = GoogleDriveService.resolveRefresh(token: "old-token", error: NSError(domain: "org.openid.appauth.general", code: -5,
                                                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)]))
                switch transient {
                case .success: t.fail("must not return the stale token")
                case .failure(let error): t.expectEqual((error as? DriveError)?.category, .offline)
                }
                // the token endpoint answered with an error page
                let serverDown = GoogleDriveService.resolveRefresh(token: "old-token", error: NSError(domain: "org.openid.appauth.general", code: -6))
                if case .failure(let error) = serverDown {
                    t.expectEqual((error as? DriveError)?.category, .server)
                } else {
                    t.fail("must not return the stale token")
                }
                let revoked = GoogleDriveService.resolveRefresh(token: nil, error: NSError(domain: "org.openid.appauth.oauth_token", code: -10))
                if case .failure(let error) = revoked {
                    t.expectEqual((error as? DriveError)?.category, .authExpired)
                } else {
                    t.fail("revoked must fail")
                }
                if case .success(let token) = GoogleDriveService.resolveRefresh(token: "new-token", error: nil) {
                    t.expectEqual(token, "new-token")
                } else {
                    t.fail("a fresh token must come through")
                }
                if case .failure(let error) = GoogleDriveService.resolveRefresh(token: nil, error: nil) {
                    t.expectEqual((error as? DriveError)?.reason, "noToken")
                } else {
                    t.fail("nothing back must fail")
                }
            },
            TestCase("disk full is told apart from unreadable") { t in
                t.expect(DriveError.isDiskFull(CocoaError(.fileWriteOutOfSpace)))
                t.expect(DriveError.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
                t.expect(DriveError.isDiskFull(NSError(domain: NSCocoaErrorDomain, code: 512,
                                                       userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])))
                t.expect(!DriveError.isDiskFull(CocoaError(.fileReadNoSuchFile)))
                t.expectEqual(DriveError(category: .other, reason: "diskFull").shortText, "Not enough disk space")
            },
            TestCase("sign-in messages: cancel is quiet, network -5 is not") { t in
                t.expectEqual(DriveViewModel.message(for: NSError(domain: kGIDSignInErrorDomain, code: -5)), nil)
                t.expect(DriveViewModel.message(for: NSError(domain: "org.openid.appauth.general", code: -5)) != nil, "appauth's -5 is a network error")
                let scope = DriveError(category: .authExpired, reason: "driveScopeNotGranted", message: "Google Drive access wasn't allowed.")
                t.expectEqual(DriveViewModel.message(for: scope), "Google Drive access wasn't allowed.")
            },
            TestCase("drive id validation") { t in
                t.expect(isValidDriveId("YOUR_TEST_FOLDER_ID"))
                t.expect(isValidDriveId("abc_DEF-123"))
                t.expect(!isValidDriveId(""))
                t.expect(!isValidDriveId("a/b"))
                t.expect(!isValidDriveId("../x"))
                t.expect(!isValidDriveId("a b"))
                t.expect(!isValidDriveId("x?y=1"))
                t.expect(!isValidDriveId("ïd"))
                t.expect(!isValidDriveId(String(repeating: "a", count: 201)))
            },
            TestCase("mime types from UTType") { t in
                t.expectEqual(DriveMime.forExtension("heic"), "image/heic")
                t.expectEqual(DriveMime.forExtension("mov"), "video/quicktime")
                t.expectEqual(DriveMime.forExtension("pdf"), "application/pdf")
                t.expectEqual(DriveMime.forExtension("txt"), "text/plain")
                t.expectEqual(DriveMime.forExtension("jpg"), "image/jpeg")
                t.expectEqual(DriveMime.forExtension("JPG"), "image/jpeg")
                for known in ["m4a", "pptx", "csv", "json", "md", "docx", "zip", "mp3", "png"] {
                    t.expect(DriveMime.forExtension(known) != nil, known)
                }
                t.expectEqual(DriveMime.forExtension(""), nil)
                t.expectEqual(DriveMime.forExtension("zzqxunknown"), nil)
            },
        ]
    }
}

// MARK: requests

enum DriveRequestTests: TestSuite {
    static let name = "DriveRequests"

    static var tests: [TestCase] {
        [
            TestCase("upload into a folder sends parents, fields and mime") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "photo.heic")
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON(id: "F1", name: "photo.heic", parents: ["P1"], mime: "image/heic")) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())

                let file = try await service.uploadFile(item, to: "P1")

                t.expectEqual(file, DriveFile(id: "F1", name: "photo.heic", parents: ["P1"], mimeType: "image/heic"))
                t.expectEqual(transport.sent.count, 1)
                guard let sent = transport.sent.first else { return }
                let url = sent.request.url!.absoluteString
                t.expect(url.hasPrefix("https://www.googleapis.com/upload/drive/v3/files?"), url)
                t.expect(url.contains("uploadType=multipart"), url)
                t.expect(url.contains("fields=id,name,parents,mimeType"), url)
                t.expectEqual(sent.method, "POST")
                t.expectEqual(sent.authorization, "Bearer t1")
                guard let boundary = DriveTestSupport.boundary(of: sent.request), let body = sent.body,
                      let parts = DriveTestSupport.parseMultipart(body, boundary: boundary) else {
                    t.fail("couldn't parse the multipart body")
                    return
                }
                t.expect(boundary.hasPrefix("Boundary-"))
                t.expectEqual(parts.metadata["name"] as? String, "photo.heic")
                t.expectEqual(parts.metadata["mimeType"] as? String, "image/heic")
                t.expectEqual(parts.metadata["parents"] as? [String], ["P1"])
                t.expectEqual(parts.mediaType, "image/heic")
                t.expectEqual(parts.media, Data("hello".utf8))
            },
            TestCase("upload to my drive has no parents") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "notes.txt")
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON(id: "F2", parents: ["ROOT"])) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                _ = try await service.uploadFile(item, to: nil)
                guard let sent = transport.sent.first, let boundary = DriveTestSupport.boundary(of: sent.request),
                      let parts = DriveTestSupport.parseMultipart(sent.body ?? Data(), boundary: boundary) else {
                    t.fail("couldn't parse the multipart body")
                    return
                }
                t.expect(parts.metadata["parents"] == nil)
                t.expectEqual(parts.metadata["mimeType"] as? String, "text/plain")
            },
            TestCase("unknown extension leaves mime to drive") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "blob.zzqxunknown")
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON()) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                _ = try await service.uploadFile(item, to: nil)
                guard let sent = transport.sent.first, let boundary = DriveTestSupport.boundary(of: sent.request),
                      let parts = DriveTestSupport.parseMultipart(sent.body ?? Data(), boundary: boundary) else {
                    t.fail("couldn't parse the multipart body")
                    return
                }
                t.expect(parts.metadata["mimeType"] == nil, "mimeType should be omitted")
                t.expectEqual(parts.mediaType, "application/octet-stream")
            },
            TestCase("any 2xx is success") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (201, DriveTestSupport.fileJSON(id: "F3")) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                let file = try await service.uploadFile(item, to: nil)
                t.expectEqual(file.id, "F3")
            },
            TestCase("401 forces one refresh and retries with the new token") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { request in
                    request.value(forHTTPHeaderField: "Authorization") == "Bearer t2"
                        ? (200, DriveTestSupport.fileJSON(id: "F4"))
                        : (401, DriveTestSupport.driveErrorBody(401, reason: "authError"))
                }
                let tokens = FakeTokens()
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                let file = try await service.uploadFile(item, to: "P1")
                t.expectEqual(file.id, "F4")
                t.expectEqual(tokens.refreshCount, 1)
                t.expectEqual(transport.sent.count, 2)
                t.expectEqual(transport.sent.map(\.authorization), ["Bearer t1", "Bearer t2"])
                // the retry sends the same body
                t.expectEqual(transport.sent.first?.body, transport.sent.last?.body)
            },
            TestCase("refresh failure after 401 is auth expired") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (401, Data()) }
                let tokens = FakeTokens()
                tokens.refreshError = NSError(domain: "org.openid.appauth.oauth_token", code: -10)
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .authExpired
                }
                t.expectEqual(tokens.refreshCount, 1)
                t.expectEqual(transport.sent.count, 1)
            },
            TestCase("a second 401 is auth expired, no loop") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (401, Data()) }
                let tokens = FakeTokens()
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .authExpired && ($0 as? DriveError)?.status == 401
                }
                t.expectEqual(tokens.refreshCount, 1)
                t.expectEqual(transport.sent.count, 2)
            },
            TestCase("offline transport error is offline") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in throw URLError(.notConnectedToInternet) }
                let tokens = FakeTokens()
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .offline
                }
                t.expectEqual(tokens.refreshCount, 0)
            },
            TestCase("offline during token refresh is offline") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON()) }
                let tokens = FakeTokens()
                tokens.accessError = DriveError.from(NSError(domain: "org.openid.appauth.general", code: -5,
                                                             userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet) as NSError]))
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .offline
                }
                t.expectEqual(transport.sent.count, 0)
            },
            TestCase("403 is permission with drive's reason") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (403, DriveTestSupport.driveErrorBody(403, reason: "insufficientFilePermissions", message: "no access to P9")) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.uploadFile(item, to: "P9") }) {
                    let error = $0 as? DriveError
                    return error?.category == .permission && error?.status == 403
                        && error?.reason == "insufficientFilePermissions" && error?.message == "no access to P9"
                }
            },
            TestCase("5xx is a server error") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (503, DriveTestSupport.driveErrorBody(503, reason: "backendError")) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .server && ($0 as? DriveError)?.shortText == "Drive error (503), retry"
                }
            },
            TestCase("--bad-token sends one invalid token, then recovers") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { request in
                    request.value(forHTTPHeaderField: "Authorization") == "Bearer invalid"
                        ? (401, Data()) : (200, DriveTestSupport.fileJSON(id: "F5"))
                }
                let tokens = FakeTokens()
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                service.sendBadTokenOnce = true
                let file = try await service.uploadFile(item, to: nil)
                t.expectEqual(file.id, "F5")
                t.expectEqual(transport.sent.map(\.authorization), ["Bearer invalid", "Bearer t2"])
                t.expectEqual(tokens.refreshCount, 1)
                t.expect(!service.sendBadTokenOnce, "flag resets")
                // next call is normal
                _ = try await service.uploadFile(item, to: nil)
                t.expectEqual(transport.sent.last?.authorization, "Bearer t1")
            },
            TestCase("not signed in fails before any request") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON()) }
                let tokens = FakeTokens()
                tokens.accessError = DriveError.notSignedIn
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .authExpired
                }
                t.expectEqual(transport.sent.count, 0)
            },
            TestCase("raw token errors are mapped too") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON()) }
                let tokens = FakeTokens()
                let service = GoogleDriveService(transport: transport, tokenSource: tokens)
                tokens.accessError = NSError(domain: "org.openid.appauth.oauth_token", code: -10)
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .authExpired
                }
                tokens.accessError = URLError(.notConnectedToInternet)
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .offline
                }
                tokens.accessError = nil
                tokens.refreshError = URLError(.timedOut)
                let unauthorized = GoogleDriveService(transport: FakeDriveTransport { _ in (401, Data()) }, tokenSource: tokens)
                await t.expectThrows({ try await unauthorized.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.category == .offline
                }
                t.expectEqual(transport.sent.count, 0)
            },
            TestCase("write-side failures aren't blamed on the file") { t in
                let dir = try t.tempDirectory()
                let source = dir.appendingPathComponent("in.txt")
                try Data("x".utf8).write(to: source)
                // the temp body can't be created: its folder doesn't exist
                let badBody = dir.appendingPathComponent("missing-folder/body")
                do {
                    try MultipartUpload.writeBody(metadata: [:], fileURL: source, mimeType: "x/y", boundary: "B", to: badBody)
                    t.fail("expected a throw")
                } catch MultipartUpload.Failure.unreadable {
                    t.fail("that's a write problem, not a read problem")
                } catch {
                    // expected
                }
                do {
                    try MultipartUpload.writeBody(metadata: [:], fileURL: dir.appendingPathComponent("nope.txt"), mimeType: "x/y", boundary: "B",
                                                  to: dir.appendingPathComponent("body"))
                    t.fail("expected a throw")
                } catch MultipartUpload.Failure.unreadable {
                    // expected
                } catch {
                    t.fail("a missing source is a read problem: \(error)")
                }
            },
            TestCase("unreadable file fails before any request") { t in
                let dir = try t.tempDirectory()
                let missing = FileItem(url: dir.appendingPathComponent("gone.txt"))
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON()) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.uploadFile(missing, to: nil) }) {
                    ($0 as? DriveError)?.reason == "readFailed"
                }
                t.expectEqual(transport.sent.count, 0)
            },
            TestCase("bad folder id is refused") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON()) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.uploadFile(item, to: "../root") }) {
                    ($0 as? DriveError)?.reason == "refused"
                }
                t.expectEqual(transport.sent.count, 0)
            },
            TestCase("upload temp body is removed after success and failure") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let before = Set(DriveTestSupport.uploadTempFiles())
                let ok = GoogleDriveService(transport: FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON()) }, tokenSource: FakeTokens())
                _ = try await ok.uploadFile(item, to: nil)
                let bad = GoogleDriveService(transport: FakeDriveTransport { _ in (500, Data()) }, tokenSource: FakeTokens())
                _ = try? await bad.uploadFile(item, to: nil)
                t.expectEqual(Set(DriveTestSupport.uploadTempFiles()), before)
            },
            TestCase("unparseable success body is a clear error") { t in
                let dir = try t.tempDirectory()
                let item = try DriveTestSupport.makeFile(in: dir, named: "a.txt")
                let service = GoogleDriveService(transport: FakeDriveTransport { _ in (200, Data("{}".utf8)) }, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.uploadFile(item, to: nil) }) {
                    ($0 as? DriveError)?.reason == "badResponse"
                }
            },
            TestCase("delete refuses destination folders without a request") { t in
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON(mime: "text/plain")) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.deleteFile(id: "DEST1", protectedIds: ["DEST1", "DEST2"]) }) {
                    ($0 as? DriveError)?.reason == "refused"
                }
                t.expectEqual(transport.sent.count, 0)
            },
            TestCase("delete refuses any folder after the GET") { t in
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.fileJSON(id: "X1", mime: DriveMime.folder)) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.deleteFile(id: "X1", protectedIds: []) }) {
                    ($0 as? DriveError)?.reason == "refused"
                }
                t.expectEqual(transport.sent.map(\.method), ["GET"])
            },
            TestCase("delete GETs then DELETEs a plain file") { t in
                let transport = FakeDriveTransport { request in
                    request.httpMethod == "DELETE" ? (204, Data()) : (200, DriveTestSupport.fileJSON(id: "F6", mime: "text/plain"))
                }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                try await service.deleteFile(id: "F6", protectedIds: ["DEST1"])
                t.expectEqual(transport.sent.map(\.method), ["GET", "DELETE"])
                let getURL = transport.sent.first?.request.url?.absoluteString ?? ""
                t.expect(getURL.hasPrefix("https://www.googleapis.com/drive/v3/files/F6?"), getURL)
                t.expect(getURL.contains("fields=id,name,mimeType"), getURL)
                t.expectEqual(transport.sent.last?.request.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/F6")
            },
            TestCase("delete of a missing file is notFound, no DELETE") { t in
                let transport = FakeDriveTransport { _ in (404, DriveTestSupport.driveErrorBody(404, reason: "notFound")) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                await t.expectThrows({ try await service.deleteFile(id: "F7", protectedIds: []) }) {
                    ($0 as? DriveError)?.category == .notFound
                }
                t.expectEqual(transport.sent.map(\.method), ["GET"])
            },
            TestCase("delete rejects ids that aren't drive ids") { t in
                let transport = FakeDriveTransport { _ in (200, Data()) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                for id in ["", "a/b", "../F1", "F1?x=1"] {
                    await t.expectThrows({ try await service.deleteFile(id: id, protectedIds: []) }) {
                        ($0 as? DriveError)?.reason == "refused"
                    }
                }
                t.expectEqual(transport.sent.count, 0)
            },
            TestCase("list folder builds the query") { t in
                let transport = FakeDriveTransport { _ in
                    (200, DriveTestSupport.json(["files": [["id": "A", "name": "a.txt", "mimeType": "text/plain"]]]))
                }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                let files = try await service.listFolder(id: "P1")
                t.expectEqual(files, [DriveFile(id: "A", name: "a.txt", parents: nil, mimeType: "text/plain")])
                let url = transport.sent.first?.request.url
                let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                t.expectEqual(items.first { $0.name == "q" }?.value, "'P1' in parents and trashed=false")
                t.expectEqual(items.first { $0.name == "fields" }?.value, "files(id,name,mimeType,parents)")
            },
            TestCase("create folder posts parents and the folder type") { t in
                let transport = FakeDriveTransport { _ in (200, DriveTestSupport.json(["id": "NEW", "name": "Receipts"])) }
                let service = GoogleDriveService(transport: transport, tokenSource: FakeTokens())
                let folder = try await service.createFolder(named: "Receipts", in: "root")
                t.expectEqual(folder, DriveFolder(id: "NEW", name: "Receipts"))
                let body = transport.sent.first?.body ?? Data()
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                t.expectEqual(json?["mimeType"] as? String, DriveMime.folder)
                t.expectEqual(json?["parents"] as? [String], ["root"])
                t.expectEqual(transport.sent.first?.authorization, "Bearer t1")
            },
            TestCase("multipart body is byte exact") { t in
                let dir = try t.tempDirectory()
                let source = dir.appendingPathComponent("in.bin")
                try Data([0, 1, 2, 255]).write(to: source)
                let out = dir.appendingPathComponent("body")
                try MultipartUpload.writeBody(metadata: ["name": "in.bin", "parents": ["P"]], fileURL: source,
                                              mimeType: "application/octet-stream", boundary: "B", to: out)
                var expected = Data("--B\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
                expected.append(Data(#"{"name":"in.bin","parents":["P"]}"#.utf8))
                expected.append(Data("\r\n--B\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
                expected.append(Data([0, 1, 2, 255]))
                expected.append(Data("\r\n--B--\r\n".utf8))
                t.expectEqual(try Data(contentsOf: out), expected)
            },
            TestCase("multipart body streams a 3 MB file intact") { t in
                let dir = try t.tempDirectory()
                let source = dir.appendingPathComponent("big.bin")
                var bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024 + 17)
                for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 7) }
                try Data(bytes).write(to: source)
                let out = dir.appendingPathComponent("body")
                try MultipartUpload.writeBody(metadata: ["name": "big.bin"], fileURL: source, mimeType: "x/y", boundary: "Boundary-1", to: out)
                guard let parts = DriveTestSupport.parseMultipart(try Data(contentsOf: out), boundary: "Boundary-1") else {
                    t.fail("couldn't parse")
                    return
                }
                t.expectEqual(parts.media.count, bytes.count)
                t.expect(parts.media == Data(bytes), "media bytes differ")
            },
            TestCase("multipart refuses folders and missing files") { t in
                let dir = try t.tempDirectory()
                let out = dir.appendingPathComponent("body")
                await t.expectThrows({ try MultipartUpload.writeBody(metadata: [:], fileURL: dir, mimeType: "x/y", boundary: "B", to: out) })
                await t.expectThrows({ try MultipartUpload.writeBody(metadata: [:], fileURL: dir.appendingPathComponent("nope"), mimeType: "x/y", boundary: "B", to: out) })
            },
        ]
    }
}
#endif
