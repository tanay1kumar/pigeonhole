#if DEBUG
import AppKit
import QuartzCore
import SwiftUI
import os

// frame pacing for the motion scenario, display link frames between start and stop
// the link runs on main, so a skipped frame means main was busy past a refresh
// a frame the render server or gpu shows late still gets an on-time callback, so it isn't counted here
@MainActor
final class FrameProbe: NSObject {
    struct Stats {
        var frames = 0
        var refresh = 1000.0 / 60       // ms per frame
        var maxGap = 0.0                // ms between two frames
        var longGaps = 0                // over 1.5x the refresh interval
        var doubleGaps = 0              // over 2x
        var missed = 0                  // refreshes main didn't get to, a gap of 2 frames is 1
        var maxLate = 0.0               // ms a callback ran after its frame, a stall past a frame gets restamped and shows as a gap
        var duration = 0.0              // ms
        var stamps: [Double] = []       // frame times, seconds

        var maxGapRatio: Double { maxGap / refresh }

        // a sleeping display or a hidden view sends no frames, and no frames means no gaps
        var starved: Bool {
            Double(frames) < duration / refresh / 2
        }

        var line: String {
            String(format: "frames: %d, max gap: %.1f ms (%.2fx), gaps > 1.5x: %d, > 2x: %d, missed: %d, max late within a frame: %.1f ms, over %.0f ms",
                   frames, maxGap, maxGapRatio, longGaps, doubleGaps, missed, maxLate, duration)
        }

        // first frame at or after a time, the earliest a committed change can show
        func firstFrame(after time: Double) -> Double? {
            stamps.first { $0 >= time }
        }
    }

    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var late: [CFTimeInterval] = []
    private var refresh: CFTimeInterval = 1.0 / 60
    private var started: CFTimeInterval = 0

    func start(on view: NSView) {
        link?.invalidate()
        stamps.removeAll(keepingCapacity: true)
        late.removeAll(keepingCapacity: true)
        started = CACurrentMediaTime()
        // the view's screen, so it follows the island's display
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        late.append(CACurrentMediaTime() - link.timestamp)
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0.001 {
            refresh = interval
        }
    }

    @discardableResult
    func stop() -> Stats {
        link?.invalidate()
        link = nil
        var stats = Stats()
        stats.refresh = refresh * 1000
        stats.frames = stamps.count
        stats.duration = (CACurrentMediaTime() - started) * 1000
        stats.stamps = stamps
        stats.maxLate = (late.max() ?? 0) * 1000
        for (previous, next) in zip(stamps, stamps.dropFirst()) {
            let gap = (next - previous) * 1000
            stats.maxGap = max(stats.maxGap, gap)
            if gap > stats.refresh * 1.5 {
                stats.longGaps += 1
            }
            if gap > stats.refresh * 2 {
                stats.doubleGaps += 1
            }
            // after a stall the link restamps, so gaps aren't exact multiples
            stats.missed += max(0, Int((gap / stats.refresh).rounded()) - 1)
        }
        return stats
    }
}

// what the motion scenario reads from the island while it runs
@MainActor
enum DebugMotion {
    // main-thread ms from each signposted change until its commit, by signpost name
    static var lastCommit: [String: (ms: Double, at: Double)] = [:]
    // each tracked open or close gets a number, so a stray one can't stand in for it
    static var generation = 0
    static var lastTracked: [String: Int] = [:]
    // when each animation finished, "expand.logical" and so on, with its number
    static var settledAt: [String: (generation: Int, at: Double)] = [:]
    // the transition each content builder returned last, open and swap, for the reduce motion check
    static var transitions: [String: String] = [:]

    // logs when the animation the island really runs is done
    // an implicit animation further down replaces the one passed in, the hooks time that one
    static func track(_ transaction: inout Transaction, _ name: String) {
        generation += 1
        let number = generation
        lastTracked[name] = number
        transaction.addAnimationCompletion(criteria: .logicallyComplete) {
            MainActor.assumeIsolated {
                settledAt[name + ".logical"] = (number, CACurrentMediaTime())
            }
        }
        transaction.addAnimationCompletion(criteria: .removed) {
            MainActor.assumeIsolated {
                settledAt[name + ".removed"] = (number, CACurrentMediaTime())
            }
        }
    }

    // ms from start until that open or close finished, nil if it never did
    static func settled(_ key: String, generation: Int?, since start: Double) -> Double? {
        guard let generation, let entry = settledAt[key], entry.generation == generation else { return nil }
        return (entry.at - start) * 1000
    }

    static func committed(_ name: String, ms: Double) {
        lastCommit[name] = (ms, CACurrentMediaTime())
    }

    static func noteTransition(_ builder: String, _ kind: String) {
        transitions[builder] = kind
    }
}

// the first animation frame where the island is wider than when it was armed
// the shape's setter can run on swiftui's render thread, so this sits behind a lock
final class GrowthStamp: @unchecked Sendable {
    static let shared = GrowthStamp()
    private let state = OSAllocatedUnfairLock<(baseline: CGFloat?, grewAt: Double?)>(initialState: (nil, nil))

    func arm(baseline: CGFloat) {
        state.withLock { $0 = (baseline, nil) }
    }

    func disarm() {
        state.withLock { $0 = (nil, nil) }
    }

    func note(width: CGFloat) {
        state.withLock { current in
            guard let baseline = current.baseline, current.grewAt == nil, width > baseline + 0.5 else { return }
            current.grewAt = CACurrentMediaTime()
        }
    }

    var grewAt: Double? {
        state.withLock { $0.grewAt }
    }
}

// body evaluations per view, for the bodies scenario
@MainActor
enum BodyCounts {
    static var counts: [String: Int] = [:]

    static func note(_ name: String) {
        counts[name, default: 0] += 1
    }

    static func reset() {
        counts = [:]
    }

    static var summary: String {
        counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}
#endif
