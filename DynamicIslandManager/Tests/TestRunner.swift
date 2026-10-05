#if DEBUG
import Foundation

// tiny in-app test runner, debug builds only:
//   DynamicIslandManager --test [filter]
// runs every suite (or the tests whose "suite/name" contains the filter), exits 0 when all pass.
// tests run on the main actor, so they can drive the view models directly.

@MainActor
final class TestContext {
    let name: String
    private(set) var failures: [String] = []

    init(name: String) {
        self.name = name
    }

    func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        failures.append("\(file):\(line) \(message)")
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
                file: StaticString = #fileID, line: UInt = #line) {
        if !condition {
            fail("expectation failed. \(message())", file: file, line: line)
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                                   file: StaticString = #fileID, line: UInt = #line) {
        if actual != expected {
            fail("expected \(expected), got \(actual). \(message())", file: file, line: line)
        }
    }

    // runs body, expects it to throw, hands the error to check
    func expectThrows<T>(_ body: () async throws -> T, _ message: String = "",
                         file: StaticString = #fileID, line: UInt = #line,
                         check: (Error) -> Bool = { _ in true }) async {
        do {
            let value = try await body()
            fail("expected a throw, got \(value). \(message)", file: file, line: line)
        } catch {
            if !check(error) {
                fail("wrong error: \(error). \(message)", file: file, line: line)
            }
        }
    }

    // polls until condition holds or the timeout passes; for timer-driven state
    @discardableResult
    func eventually(_ message: String = "", timeout: Double = 2, file: StaticString = #fileID, line: UInt = #line,
                    _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if condition() { return true }
        fail("timed out after \(timeout)s. \(message)", file: file, line: line)
        return false
    }

    // a fresh temp folder for this test
    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dim-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct TestCase {
    let name: String
    let body: @MainActor (TestContext) async throws -> Void

    init(_ name: String, _ body: @escaping @MainActor (TestContext) async throws -> Void) {
        self.name = name
        self.body = body
    }
}

protocol TestSuite {
    static var name: String { get }
    @MainActor static var tests: [TestCase] { get }
}

enum TestRunner {
    // every suite, in run order
    static let suites: [TestSuite.Type] = [
        DriveErrorTests.self,
        DriveRequestTests.self,
        ZipUtilityTests.self,
        IslandStatusTests.self,
        FeatureVectorTests.self,
        FilePatternTests.self,
        FeatureExtractorTests.self,
    ]

    @MainActor
    static func run(filter: String?) async -> Int32 {
        var passed = 0
        var failed: [String] = []
        let started = DispatchTime.now()

        for suite in suites {
            for test in suite.tests {
                let fullName = "\(suite.name)/\(test.name)"
                if let filter, !fullName.localizedCaseInsensitiveContains(filter) {
                    continue
                }
                let context = TestContext(name: fullName)
                let start = DispatchTime.now()
                do {
                    try await test.body(context)
                } catch {
                    context.fail("threw \(error)")
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                if context.failures.isEmpty {
                    passed += 1
                    print(String(format: "PASS %@ (%.0f ms)", fullName, ms))
                } else {
                    failed.append(fullName)
                    print(String(format: "FAIL %@ (%.0f ms)", fullName, ms))
                    for failure in context.failures {
                        print("    \(failure)")
                    }
                }
            }
        }

        let total = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        print(String(format: "\n%d passed, %d failed (%.1f s)", passed, failed.count, total))
        for name in failed {
            print("  failed: \(name)")
        }
        if passed + failed.count == 0 {
            print("no tests matched \(filter ?? "")")
            return 2
        }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("dim-tests"))
        return failed.isEmpty ? 0 : 1
    }
}
#endif
