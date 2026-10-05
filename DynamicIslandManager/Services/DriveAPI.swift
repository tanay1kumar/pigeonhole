import Foundation
import UniformTypeIdentifiers

// what drive sends back for a file
struct DriveFile: Decodable, Equatable {
    let id: String
    let name: String
    let parents: [String]?
    let mimeType: String?
    var size: String? = nil     // only when asked for (fields=...,size); drive sends int64 as a string
}

// one error type for every drive call, so the island can say what went wrong
struct DriveError: LocalizedError, Equatable {
    enum Category: String, Equatable {
        case authExpired, permission, notFound, offline, server, other
    }

    let category: Category
    var status: Int?
    var reason: String?
    var message: String?

    init(category: Category, status: Int? = nil, reason: String? = nil, message: String? = nil) {
        self.category = category
        self.status = status
        self.reason = reason
        self.message = message
    }

    static let notSignedIn = DriveError(category: .authExpired, reason: "notSignedIn", message: "Not signed in to Google")

    static func refused(_ message: String) -> DriveError {
        DriveError(category: .other, reason: "refused", message: message)
    }

    // short text for the island
    var shortText: String {
        switch category {
        case .authExpired: return "Signed out — Sign in again"
        case .permission: return "No access to that folder"
        // under drive.file a folder the app lost access to is a 404 too
        case .notFound: return "Can't reach that folder (deleted or no access)"
        case .offline: return "You're offline"
        case .server:
            if let status, status >= 500 { return "Drive error (\(status)), retry" }
            return "Drive is busy, retry"
        case .other:
            if reason == "storageQuotaExceeded" { return "Your Drive is full" }
            if reason == "diskFull" { return "Not enough disk space" }
            if reason == "prepareFailed" { return message ?? "Couldn't prepare the upload" }
            if reason == "readFailed" { return message ?? "Couldn't read the file" }
            if let status { return "Drive error (\(status))" }
            return "Upload failed"
        }
    }

    // full detail for logs and the cli
    var errorDescription: String? {
        var parts = [category.rawValue]
        if let status { parts.append("HTTP \(status)") }
        if let reason { parts.append(reason) }
        if let message { parts.append(message) }
        return parts.joined(separator: " · ")
    }

    // 403 reasons that mean "slow down", not "no access"
    private static let rateLimitReasons: Set<String> = [
        "rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded", "sharingRateLimitExceeded"
    ]

    // 403 reasons that mean the sign-in is missing the drive scope: only signing in again fixes that
    private static let scopeReasons: Set<String> = [
        "insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"
    ]

    // an http error status plus drive's json error body
    static func http(status: Int, body: Data) -> DriveError {
        let (reason, message) = parseBody(body)
        let category: Category
        switch status {
        case 401:
            category = .authExpired
        case 403:
            if let reason, scopeReasons.contains(reason) {
                category = .authExpired
            } else if let reason, rateLimitReasons.contains(reason) {
                category = .server
            } else if reason == "storageQuotaExceeded" {
                category = .other
            } else {
                category = .permission
            }
        case 404:
            category = .notFound
        case 429, 500...599:
            category = .server
        default:
            category = .other
        }
        return DriveError(category: category, status: status, reason: reason, message: message)
    }

    // {"error": {"code", "message", "errors": [{"reason"}], "status", "details": [{"reason"}]}}
    static func parseBody(_ body: Data) -> (reason: String?, message: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            let text = String(decoding: body.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text.isEmpty ? nil : text)
        }
        let first = (error["errors"] as? [[String: Any]])?.first
        let detail = (error["details"] as? [[String: Any]])?.first { $0["reason"] is String }
        let reason = first?["reason"] as? String ?? detail?["reason"] as? String ?? error["status"] as? String
        let message = error["message"] as? String ?? first?["message"] as? String
        return (reason, message)
    }

    // anything thrown by urlsession, google sign-in or appauth
    static func from(_ error: Error) -> DriveError {
        if let driveError = error as? DriveError {
            return driveError
        }
        if error is CancellationError {
            return DriveError(category: .other, reason: "cancelled", message: "Cancelled")
        }
        let nsError = error as NSError
        // a dead refresh token (revoked, or the 7-day testing expiry)
        if nsError.domain == "org.openid.appauth.oauth_token" {
            return DriveError(category: .authExpired, reason: "refresh \(nsError.code)", message: nsError.localizedDescription)
        }
        if isOffline(nsError) {
            return DriveError(category: .offline, reason: "\(nsError.domain) \(nsError.code)", message: nsError.localizedDescription)
        }
        // google's token endpoint answered with an error page: worth a retry
        if nsError.domain == "org.openid.appauth.general" && nsError.code == -6 {
            return DriveError(category: .server, reason: "\(nsError.domain) \(nsError.code)", message: nsError.localizedDescription)
        }
        if nsError.domain == "com.google.GIDSignIn" {
            return DriveError(category: .authExpired, reason: "\(nsError.domain) \(nsError.code)", message: nsError.localizedDescription)
        }
        return DriveError(category: .other, reason: "\(nsError.domain) \(nsError.code)", message: nsError.localizedDescription)
    }

    // no space to write the multipart body
    static func isDiskFull(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isDiskFull(underlying)
        }
        return false
    }

    // urlsession errors, also when appauth wraps them
    private static func isOffline(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            return error.code != NSURLErrorCancelled
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOffline(underlying)
        }
        return false
    }
}

// sends drive requests, swapped for a fake in tests
protocol DriveTransport {
    func send(_ request: URLRequest, bodyFile: URL?) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionDriveTransport: DriveTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest, bodyFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        if let bodyFile {
            // still about 1x the file in memory (urlsession buffers the body), not 2x like before
            (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriveError(category: .other, reason: "noHTTPResponse", message: "Drive sent no HTTP response")
        }
        return (data, http)
    }
}

enum DriveMime {
    static let folder = "application/vnd.google-apps.folder"

    // nil when macOS doesn't know the extension, drive then guesses from the name
    static func forExtension(_ fileExtension: String) -> String? {
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }
}

enum MultipartUpload {
    // the source file vs the temp body, so the island can say which went wrong
    enum Failure: Error {
        case unreadable(Error)
    }

    // writes the multipart/related body to a file, so big uploads never sit in memory twice
    static func writeBody(metadata: [String: Any], fileURL: URL, mimeType: String,
                          boundary: String, to bodyURL: URL) throws {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw Failure.unreadable(error)
        }
        defer { try? input.close() }

        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        try output.write(contentsOf: metadataData)
        try output.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        // copy in 1 MB chunks
        while true {
            let chunk: Data
            do {
                guard let next = try input.read(upToCount: 1 << 20), !next.isEmpty else { break }
                chunk = next
            } catch {
                throw Failure.unreadable(error)
            }
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}

// drive ids are letters, digits, - and _; anything else never goes into a url path
func isValidDriveId(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 200 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
}
