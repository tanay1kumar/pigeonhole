import Foundation
import QuartzCore

// resumable upload for big files, sent in 8 MiB chunks read from disk
// drive keeps the session for about a week, nothing here keeps it across launches
enum ResumableUpload {
    // drive suggests resumable above 5 MB, smaller files go multipart
    static let threshold: Int64 = 5 * 1024 * 1024
    // a multiple of 256 KiB, only the last chunk may be smaller
    static let chunkSize = 8 * 1024 * 1024
    // waits before asking where the upload got to, after a 5xx or going offline
    static let retryDelays: [Double] = [1, 2, 4]
    // a 404 or 410 on the session, drive dropped it
    static let expiredReason = "sessionExpired"

    static func shouldUse(size: Int64) -> Bool {
        size > threshold
    }

    // "bytes=0-1048575" means the next byte to send is 1048576
    // no range header means nothing arrived yet
    static func nextOffset(rangeHeader: String?) -> Int64? {
        guard let header = rangeHeader?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return 0 }
        guard let dash = header.lastIndex(of: "-"), let end = Int64(header[header.index(after: dash)...].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return end + 1
    }

    // "bytes 0-8388607/52428800", or "bytes */52428800" to ask where it got to
    static func contentRange(start: Int64, length: Int, total: Int64) -> String {
        guard length > 0 else { return "bytes */\(total)" }
        return "bytes \(start)-\(start + Int64(length) - 1)/\(total)"
    }
}

// about 10 progress updates a second, the newest one held back gets sent when the time comes
// urlsession reports a chunk in bursts, so dropping would lose where a burst ended
final class ProgressThrottle: @unchecked Sendable {
    enum Decision: Equatable {
        case now
        case later(CFTimeInterval)      // the caller flushes after this long
        case drop                       // older than what was sent, or a flush is already coming
    }

    private let lock = NSLock()
    private var last: CFTimeInterval = -.infinity
    private var lastFraction = -1.0
    private var pending: Double?
    private var flushScheduled = false
    let interval: CFTimeInterval

    init(interval: CFTimeInterval = 0.1) {
        self.interval = interval
    }

    func offer(_ fraction: Double, now: CFTimeInterval = CACurrentMediaTime()) -> Decision {
        lock.withLock {
            guard fraction > lastFraction, fraction > (pending ?? -1) else { return .drop }
            if fraction >= 1 || now - last >= interval {
                last = now
                lastFraction = fraction
                pending = nil
                return .now
            }
            pending = fraction
            guard !flushScheduled else { return .drop }
            flushScheduled = true
            return .later(interval - (now - last))
        }
    }

    // the value held back, nil if a newer one already went out
    func takePending(now: CFTimeInterval = CACurrentMediaTime()) -> Double? {
        lock.withLock {
            flushScheduled = false
            guard let value = pending, value > lastFraction else { return nil }
            pending = nil
            last = now
            lastFraction = value
            return value
        }
    }
}
