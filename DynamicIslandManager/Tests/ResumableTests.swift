#if DEBUG
import Foundation

// a pretend drive that speaks the resumable protocol, with failures on cue
final class FakeResumableServer: DriveTransport, @unchecked Sendable {
    enum Failure {
        case status(Int)            // answer this instead of storing the chunk
        case offline                // the connection drops before anything arrives
        case keepOnly(Int)          // keep only this many bytes of the chunk
        case expire                 // the session is gone from here on
        case unauthorized           // one 401, then the retry works
        case keepThenDrop(Int)      // keep this many bytes, then the connection drops before the reply
    }

    private let lock = NSLock()
    private var stored = Data()
    private var total: Int64 = 0
    private var sessionNumber = 0
    private var expired: Set<Int> = []
    private var chunkCount = 0
    private var linkAsked = false
    private(set) var log: [String] = []
    private(set) var metadata: [String: Any] = [:]
    var failures: [Int: Failure] = [:]      // by chunk number, from 0
    var name = "file"

    var received: Data { lock.withLock { stored } }
    var sessionsStarted: Int { lock.withLock { sessionNumber } }
    var events: [String] { lock.withLock { log } }

    func send(_ request: URLRequest, bodyFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        func reply(_ status: Int, _ headers: [String: String] = [:], _ body: Data = Data()) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        if method == "POST" {
            return lock.withLock {
                sessionNumber += 1
                // drive only sends the link when fields asks for it
                linkAsked = url.query?.contains("webViewLink") == true
                stored = Data()
                total = Int64(request.value(forHTTPHeaderField: "X-Upload-Content-Length") ?? "") ?? -1
                metadata = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
                log.append("start \(sessionNumber) \(total)")
                return reply(200, ["Location": "https://upload.example/session/\(sessionNumber)"])
            }
        }
        let session = Int(url.lastPathComponent) ?? -1
        let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
        let body = request.httpBody ?? Data()
        // a dropped connection stores nothing
        let failure: Failure? = lock.withLock {
            guard !range.hasPrefix("bytes */") else { return nil }
            let failure = failures.removeValue(forKey: chunkCount)
            chunkCount += 1
            return failure
        }
        if case .offline = failure {
            lock.withLock { log.append("put \(range) dropped") }
            throw URLError(.notConnectedToInternet)
        }
        return try lock.withLock {
            if expired.contains(session) || session != sessionNumber {
                log.append("put \(range) 404")
                return reply(404)
            }
            if range.hasPrefix("bytes */") {
                let header = stored.isEmpty ? [:] : ["Range": "bytes=0-\(stored.count - 1)"]
                if Int64(stored.count) == total {
                    log.append("query 200")
                    return reply(200, [:], fileJSON())
                }
                log.append("query 308 \(header["Range"] ?? "none")")
                return reply(308, header)
            }
            // "bytes a-b/total", it has to start where drive is
            let numbers = range.dropFirst("bytes ".count).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int64($0) }
            guard numbers.count == 3, numbers[0] == Int64(stored.count), numbers[1] - numbers[0] + 1 == Int64(body.count) else {
                log.append("put \(range) 400 out of order")
                return reply(400)
            }
            switch failure {
            case .status(let code):
                log.append("put \(range) \(code)")
                return reply(code)
            case .keepOnly(let count):
                stored.append(body.prefix(count))
                log.append("put \(range) 308 kept \(count)")
                return reply(308, ["Range": "bytes=0-\(stored.count - 1)"])
            case .expire:
                expired.insert(session)
                log.append("put \(range) 404 expired")
                return reply(404)
            case .unauthorized:
                failures[chunkCount - 1] = nil
                chunkCount -= 1
                log.append("put \(range) 401")
                return reply(401)
            case .keepThenDrop(let count):
                let kept = body.prefix(count)
                stored.append(kept)
                log.append("put \(range) kept \(kept.count), dropped")
                throw URLError(.networkConnectionLost)
            default:
                stored.append(body)
                if Int64(stored.count) == total {
                    log.append("put \(range) 200")
                    return reply(200, [:], fileJSON())
                }
                log.append("put \(range) 308")
                return reply(308, ["Range": "bytes=0-\(stored.count - 1)"])
            }
        }
    }

    private func fileJSON() -> Data {
        var object: [String: Any] = ["id": "R1", "name": name, "parents": (metadata["parents"] as? [String]) ?? [],
                                     "mimeType": "application/octet-stream"]
        if linkAsked {
            object["webViewLink"] = "https://drive.google.com/file/d/R1/view?usp=drivesdk"
        }
        return DriveTestSupport.json(object)
    }
}

// what a sendable callback saw, it can run off main
final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}

enum ResumableTests: TestSuite {
    static let name = "Resumable"

    @MainActor
    static func makeFile(_ t: TestContext, size: Int, name: String = "big.bin") throws -> FileItem {
        let url = try t.tempDirectory().appendingPathComponent(name)
        // a pattern that changes every byte, so a chunk in the wrong place shows
        var bytes = [UInt8](repeating: 0, count: size)
        for index in 0..<size {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 8)
        }
        try Data(bytes).write(to: url)
        return FileItem(url: url)
    }

    @MainActor
    static func service(_ server: FakeResumableServer) -> GoogleDriveService {
        let service = GoogleDriveService(transport: server, tokenSource: FakeTokens())
        service.resumableRetryDelays = [0.01, 0.02, 0.04]
        return service
    }

    static var tests: [TestCase] {
        [
            TestCase("a 20 MB file goes up in 8 MiB chunks, with progress and its link") { t in
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                let seen = TestBox<[Double]>([])
                let file = try await service(server).uploadFile(item, to: "folder1", progress: { value in seen.update { $0.append(value) } })
                let progress = seen.value
                t.expectEqual(file.webViewLink, "https://drive.google.com/file/d/R1/view?usp=drivesdk")
                t.expectEqual(file.parents, ["folder1"])
                t.expectEqual(server.received, try Data(contentsOf: item.url))
                t.expectEqual(server.events, ["start 1 20000000",
                                              "put bytes 0-8388607/20000000 308",
                                              "put bytes 8388608-16777215/20000000 308",
                                              "put bytes 16777216-19999999/20000000 200"])
                t.expect(progress == progress.sorted() && progress.last == 1, "\(progress)")
            },
            TestCase("where drive kept part of a chunk, the next one starts there") { t in
                let item = try makeFile(t, size: 9_000_000)
                let server = FakeResumableServer()
                server.failures = [0: .keepOnly(5_000_000)]
                _ = try await service(server).uploadFile(item, to: nil)
                t.expectEqual(server.received, try Data(contentsOf: item.url))
                t.expectEqual(server.events[2], "put bytes 5000000-8999999/9000000 200")
            },
            TestCase("a 5xx mid-upload waits, asks where it got to, and goes on from there") { t in
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                server.failures = [1: .status(503)]
                _ = try await service(server).uploadFile(item, to: nil)
                t.expectEqual(server.received, try Data(contentsOf: item.url))
                t.expect(server.events.contains("query 308 bytes=0-8388607"), "\(server.events)")
                t.expectEqual(server.sessionsStarted, 1, "resumed, not started over")
            },
            TestCase("dropped offline after chunk 2, it resumes from drive's offset, not from zero") { t in
                let item = try makeFile(t, size: 30_000_000)
                let server = FakeResumableServer()
                server.failures = [2: .offline]
                _ = try await service(server).uploadFile(item, to: nil)
                t.expectEqual(server.received, try Data(contentsOf: item.url))
                let events = server.events
                t.expect(events.contains("query 308 bytes=0-16777215"), "\(events)")
                t.expect(events.contains("put bytes 16777216-25165823/30000000 308"), "the third chunk again: \(events)")
                t.expect(!events.dropFirst(3).contains { $0.hasPrefix("put bytes 0-") }, "nothing sent from zero again")
            },
            TestCase("dropped mid-chunk, it goes on from what drive kept, not its own offset") { t in
                let item = try makeFile(t, size: 30_000_000)
                let server = FakeResumableServer()
                server.failures = [2: .keepThenDrop(4 * 1024 * 1024)]
                _ = try await service(server).uploadFile(item, to: nil)
                t.expectEqual(server.received, try Data(contentsOf: item.url))
                t.expect(server.events.contains("query 308 bytes=0-20971519"), "\(server.events)")
                t.expect(server.events.contains("put bytes 20971520-29360127/30000000 308"), "\(server.events)")
            },
            TestCase("the last reply is lost, asking where it got to gets the file") { t in
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                server.failures = [2: .keepThenDrop(Int.max)]
                let file = try await service(server).uploadFile(item, to: nil)
                t.expectEqual(file.id, "R1")
                t.expectEqual(server.received, try Data(contentsOf: item.url))
                t.expectEqual(server.events.last, "query 200")
                t.expectEqual(server.sessionsStarted, 1)
            },
            TestCase("an expired session starts over once, a second one fails") { t in
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                server.failures = [1: .expire]
                _ = try await service(server).uploadFile(item, to: nil)
                t.expectEqual(server.sessionsStarted, 2)
                t.expectEqual(server.received, try Data(contentsOf: item.url))

                let again = FakeResumableServer()
                again.failures = [1: .expire, 3: .expire]
                await t.expectThrows({ try await service(again).uploadFile(item, to: nil) }) {
                    (($0 as? DriveError)?.reason) == ResumableUpload.expiredReason
                }
                t.expectEqual(again.sessionsStarted, 2, "starts over only once")
            },
            TestCase("a 401 mid-upload refreshes the token and resumes") { t in
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                server.failures = [1: .unauthorized]
                let tokens = FakeTokens()
                let service = GoogleDriveService(transport: server, tokenSource: tokens)
                _ = try await service.uploadFile(item, to: nil)
                t.expectEqual(tokens.refreshCount, 1)
                t.expectEqual(server.sessionsStarted, 1)
                t.expectEqual(server.received, try Data(contentsOf: item.url))
            },
            TestCase("three retries, then a fourth failure in a row gives up") { t in
                t.expectEqual(ResumableUpload.retryDelays, [1, 2, 4])
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                server.failures = [1: .offline, 2: .offline, 3: .offline, 4: .offline]
                await t.expectThrows({ try await service(server).uploadFile(item, to: nil) }) {
                    DriveError.from($0).category == .offline
                }
                // one question per retry, a fifth try would have gone through
                t.expectEqual(server.events.filter { $0.hasPrefix("query") }.count, 3, "\(server.events)")
                t.expectEqual(server.events.filter { $0.hasSuffix("dropped") }.count, 4, "\(server.events)")
            },
            TestCase("a file that gets shorter mid-upload fails instead of asking forever") { t in
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                let url = item.url
                let cut = TestBox(false)
                await t.expectThrows({
                    try await service(server).uploadFile(item, to: nil, progress: { fraction in
                        // after the first chunk is in, the file loses its end
                        guard fraction > 0.3, fraction < 1 else { return }
                        cut.update { done in
                            guard !done, let handle = try? FileHandle(forWritingTo: url) else { return }
                            try? handle.truncate(atOffset: 10_000_000)
                            try? handle.close()
                            done = true
                        }
                    })
                }) { (($0 as? DriveError)?.reason) == "readFailed" }
                t.expect(cut.value, "the file was cut")
                t.expect(!server.events.contains { $0.hasPrefix("query") }, "\(server.events)")
            },
            TestCase("a cancelled request is a stop, not a failure") { t in
                t.expect(DriveError.from(URLError(.cancelled)).isCancelled)
                t.expect(DriveError.from(CancellationError()).isCancelled)
                t.expect(!DriveError.from(URLError(.notConnectedToInternet)).isCancelled)
            },
            TestCase("other 4xx fail the upload without retries") { t in
                let item = try makeFile(t, size: 20_000_000)
                let server = FakeResumableServer()
                server.failures = [1: .status(403)]
                await t.expectThrows({ try await service(server).uploadFile(item, to: nil) }) {
                    DriveError.from($0).status == 403
                }
                t.expect(!server.events.contains { $0.hasPrefix("query") }, "\(server.events)")
            },
            TestCase("cancel stops between chunks") { t in
                let item = try makeFile(t, size: 30_000_000)
                let server = FakeResumableServer()
                let drive = service(server)
                let box = TestBox<Task<DriveFile, Error>?>(nil)
                let task = Task {
                    try await drive.uploadFile(item, to: nil, progress: { fraction in
                        // after the first chunk is in
                        if fraction > 0.25 { box.value?.cancel() }
                    })
                }
                box.update { $0 = task }
                await t.expectThrows({ try await task.value }) { error in
                    DriveError.from(error).isCancelled
                }
                t.expect(server.events.count <= 3, "stopped early: \(server.events)")
            },
            TestCase("which files go resumable, by size") { t in
                for (size, resumable) in [(0, false), (5 * 1024 * 1024, false), (5 * 1024 * 1024 + 1, true),
                                          (8 * 1024 * 1024, true), (8 * 1024 * 1024 + 1, true)] {
                    let item = try makeFile(t, size: size, name: "f\(size).bin")
                    let server = FakeResumableServer()
                    let fake = FakeDriveTransport { request in
                        (200, DriveTestSupport.fileJSON(id: "M1", name: "f"))
                    }
                    let service = GoogleDriveService(transport: resumable ? server : fake, tokenSource: FakeTokens())
                    _ = try? await service.uploadFile(item, to: nil)
                    if resumable {
                        t.expectEqual(server.sessionsStarted, 1, "\(size) bytes goes resumable")
                        t.expectEqual(Int64(server.received.count), Int64(size))
                    } else {
                        t.expect(fake.sent.first?.request.url?.query?.contains("uploadType=multipart") == true, "\(size) bytes goes multipart")
                    }
                }
                // 8 MiB and 1 byte, a full chunk then a 1 byte one
                let item = try makeFile(t, size: 8 * 1024 * 1024 + 1, name: "edge.bin")
                let server = FakeResumableServer()
                _ = try await service(server).uploadFile(item, to: nil)
                t.expectEqual(server.events.last, "put bytes 8388608-8388608/8388609 200")
            },
            TestCase("--resumable sends a small file the resumable way") { t in
                let item = try makeFile(t, size: 1000)
                let server = FakeResumableServer()
                let drive = service(server)
                drive.forceResumable = true
                let file = try await drive.uploadFile(item, to: nil)
                t.expectEqual(server.events, ["start 1 1000", "put bytes 0-999/1000 200"])
                t.expect(file.webViewLink != nil)
            },
            TestCase("both upload paths ask drive for the link") { t in
                let fake = FakeDriveTransport { _ in (200, DriveTestSupport.json(["id": "M1", "name": "a.txt",
                                                                                  "webViewLink": "https://drive.google.com/file/d/M1/view"])) }
                let item = try DriveTestSupport.makeFile(in: try t.tempDirectory(), named: "a.txt")
                let file = try await GoogleDriveService(transport: fake, tokenSource: FakeTokens()).uploadFile(item, to: nil)
                t.expectEqual(file.webViewLink, "https://drive.google.com/file/d/M1/view")
                t.expect(fake.sent.first?.request.url?.query?.contains("webViewLink") == true)
            },
            TestCase("about decodes the quota, unlimited when there's no limit") { t in
                let fake = FakeDriveTransport { request in
                    t.expect(request.url?.absoluteString.contains("drive/v3/about") == true)
                    return (200, DriveTestSupport.json(["storageQuota": ["limit": "16106127360", "usage": "4294967296",
                                                                          "usageInDrive": "1073741824", "usageInDriveTrash": "125829120"],
                                                         "user": ["emailAddress": "someone@example.com", "displayName": "Someone"]]))
                }
                let about = try await GoogleDriveService(transport: fake, tokenSource: FakeTokens()).about()
                t.expectEqual(about.limit, 16_106_127_360)
                t.expectEqual(about.free, 16_106_127_360 - 4_294_967_296)
                t.expectEqual(about.otherUsage, 4_294_967_296 - 1_073_741_824)
                t.expectEqual(about.trash, 125_829_120)
                t.expectEqual(about.user?.emailAddress, "someone@example.com")
                let unlimited = try JSONDecoder().decode(DriveAbout.self, from: DriveTestSupport.json(["storageQuota": ["usage": "10"]]))
                t.expect(unlimited.limit == nil && unlimited.free == nil && unlimited.usedFraction == nil)
            },
            TestCase("range headers") { t in
                t.expectEqual(ResumableUpload.nextOffset(rangeHeader: "bytes=0-8388607"), 8_388_608)
                t.expectEqual(ResumableUpload.nextOffset(rangeHeader: " bytes=0-0 "), 1)
                t.expectEqual(ResumableUpload.nextOffset(rangeHeader: nil), 0)
                t.expectEqual(ResumableUpload.nextOffset(rangeHeader: ""), 0)
                t.expect(ResumableUpload.nextOffset(rangeHeader: "bytes=0-") == nil)
                t.expectEqual(ResumableUpload.contentRange(start: 0, length: 10, total: 20), "bytes 0-9/20")
                t.expectEqual(ResumableUpload.contentRange(start: 0, length: 0, total: 20), "bytes */20")
            },
        ]
    }
}
#endif
