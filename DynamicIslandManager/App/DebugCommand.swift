import Foundation
import Security

// all command line modes, no ui and no user defaults writes
//   --debug-list-destinations
//   --debug-upload <file> <folderId|root> [--bad-token] [--resumable] [--drop-after-chunk N]
//   --debug-about
//   --debug-delete <fileId>
//   --debug-list-folder <folderId>
//   --features <file>... [--repeat N] [--idle [S]] [--prewarm] [--diag-boxes]
//   --eval <dir> [--hints h.json] [--runs N] [--seed S] [--json out.json] [--params p.json] [--diag-boxes]
//   --selftest write|verify             (debug builds, temp store only)
//   --test [name filter]                (debug builds)
// exit codes: 0 ok, 1 failed, 2 usage
enum DebugCommand {
    case listDestinations
    case upload(path: String, folderId: String, badToken: Bool, resumable: Bool, dropAfterChunk: Int?)
    case about
    case delete(fileId: String)
    case listFolder(folderId: String)
    case features(paths: [String], repeats: Int, idle: Double, diagBoxes: Bool, prewarm: Bool)
    case eval(Eval.Options)
    case selfTest(mode: String)
    case test(filter: String?)
    case usage(String)

    static func parse(_ arguments: [String]) -> DebugCommand? {
        // search, xcode adds -NSDocumentRevisionsDebugMode YES
        func values(after flag: String, _ count: Int) -> [String]? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            let rest = arguments.dropFirst(index + 1).prefix(count)
            guard rest.count == count, !rest.contains(where: { $0.hasPrefix("-") && $0 != "-" }) else { return [] }
            return Array(rest)
        }

        if arguments.contains("--debug-list-destinations") {
            return .listDestinations
        }
        if let args = values(after: "--debug-upload", 2) {
            let usage = "--debug-upload <file> <folderId|root> [--bad-token] [--resumable] [--drop-after-chunk N]"
            guard args.count == 2 else { return .usage(usage) }
            var drop: Int?
            if arguments.contains("--drop-after-chunk") {
                guard let value = values(after: "--drop-after-chunk", 1)?.first.flatMap({ Int($0) }), value >= 0 else { return .usage(usage) }
                drop = value
            }
            return .upload(path: args[0], folderId: args[1], badToken: arguments.contains("--bad-token"),
                           resumable: arguments.contains("--resumable"), dropAfterChunk: drop)
        }
        if arguments.contains("--debug-about") {
            return .about
        }
        if let args = values(after: "--debug-delete", 1) {
            guard args.count == 1 else { return .usage("--debug-delete <fileId>") }
            return .delete(fileId: args[0])
        }
        if let args = values(after: "--debug-list-folder", 1) {
            guard args.count == 1 else { return .usage("--debug-list-folder <folderId>") }
            return .listFolder(folderId: args[0])
        }
        if let index = arguments.firstIndex(of: "--features") {
            let paths = Array(arguments.dropFirst(index + 1).prefix { !$0.hasPrefix("--") })
            guard !paths.isEmpty else { return .usage("--features <file>... [--repeat N] [--idle [S]] [--diag-boxes]") }
            func number(after flag: String) -> Double? {
                guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else { return nil }
                return Double(arguments[flagIndex + 1])
            }
            let repeats = Int(number(after: "--repeat") ?? 0)
            let idle = arguments.contains("--idle") ? (number(after: "--idle") ?? 10) : 0
            return .features(paths: paths, repeats: max(0, repeats), idle: max(0, idle), diagBoxes: arguments.contains("--diag-boxes"),
                             prewarm: arguments.contains("--prewarm"))
        }
        if let args = values(after: "--eval", 1) {
            let usage = "--eval <dir> [--hints h.json] [--runs N] [--seed S] [--json out.json] [--params p.json] [--diag-boxes]"
            guard args.count == 1 else { return .usage(usage) }
            var options = Eval.Options(directory: URL(fileURLWithPath: args[0], isDirectory: true))
            func path(after flag: String) -> URL? {
                values(after: flag, 1).flatMap { $0.first }.map { URL(fileURLWithPath: $0) }
            }
            func number(after flag: String) -> UInt64? {
                values(after: flag, 1).flatMap { $0.first }.flatMap { UInt64($0) }
            }
            if arguments.contains("--hints") {
                guard let url = path(after: "--hints") else { return .usage(usage) }
                options.hintsURL = url
            }
            if arguments.contains("--params") {
                guard let url = path(after: "--params") else { return .usage(usage) }
                options.paramsURL = url
            }
            if arguments.contains("--json") {
                guard let url = path(after: "--json") else { return .usage(usage) }
                options.jsonURL = url
            }
            if arguments.contains("--runs") {
                guard let runs = number(after: "--runs"), runs > 0 else { return .usage(usage) }
                options.runs = Int(runs)
            }
            if arguments.contains("--seed") {
                guard let seed = number(after: "--seed") else { return .usage(usage) }
                options.seed = seed
            }
            options.diagBoxes = arguments.contains("--diag-boxes")
            return .eval(options)
        }
        if let args = values(after: "--selftest", 1) {
            guard args.count == 1, ["write", "verify"].contains(args[0]) else { return .usage("--selftest write|verify") }
            return .selfTest(mode: args[0])
        }
        if let index = arguments.firstIndex(of: "--test") {
            let filter = arguments.dropFirst(index + 1).first.flatMap { $0.hasPrefix("-") ? nil : $0 }
            return .test(filter: filter)
        }
        return nil
    }

    @MainActor
    func run(drive: () -> GoogleDriveService, store: DestinationStore) async -> Int32 {
        switch self {
        case .usage(let text):
            print("usage: \(text)")
            return 2

        case .listDestinations:
            if store.destinations.isEmpty {
                print("no destinations")
            }
            for destination in store.destinations {
                print("\(destination.id)\t\(destination.name)\t\(destination.path)")
            }
            return 0

        case .features(let paths, let repeats, let idle, let diagBoxes, let prewarm):
            return await FeaturesReport.run(paths: paths, repeats: repeats, idle: idle, diagBoxes: diagBoxes, prewarm: prewarm)

        case .eval(let options):
            return await Eval.run(options)

        case .selfTest(let mode):
            #if DEBUG
            return await SelfTest.run(mode: mode)
            #else
            print("--selftest needs a debug build")
            return 2
            #endif

        case .test(let filter):
            #if DEBUG
            return await TestRunner.run(filter: filter)
            #else
            print("--test needs a debug build")
            return 2
            #endif

        case .upload(let path, let folderId, let badToken, let resumable, let dropAfterChunk):
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("no such file: \(path)")
                return 2
            }
            let item = FileItem(url: url)
            guard !item.isDirectory else {
                print("that's a folder, zip it first")
                return 2
            }
            let service = drive()
            guard await restore(service) else { return 1 }
            service.sendBadTokenOnce = badToken
            service.forceResumable = resumable
            #if DEBUG
            service.dropAfterChunk = dropAfterChunk
            #else
            if dropAfterChunk != nil {
                print("--drop-after-chunk needs a debug build")
                return 2
            }
            #endif
            // peak memory while it uploads, sampled every 100 ms
            let base = physFootprintMB()
            let sampler = Task.detached { () -> Double in
                var peak = physFootprintMB()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    peak = max(peak, physFootprintMB())
                }
                return peak
            }
            let started = DispatchTime.now()
            let report = IslandViewModel.progressReporter { fraction in
                print(String(format: "progress: %.0f%%", fraction * 100))
            }
            do {
                let file = try await service.uploadFile(item, to: folderId == "root" ? nil : folderId, progress: report)
                sampler.cancel()
                let peak = await sampler.value
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
                print("id: \(file.id)")
                print("name: \(file.name)")
                print("parents: \(file.parents ?? [])")
                print("mimeType: \(file.mimeType ?? "-")")
                print("webViewLink: \(file.webViewLink ?? "-")")
                print(String(format: "took %.1f s, memory %.1f MB before, peak %.1f MB (+%.1f)", seconds, base, peak, peak - base))
                if folderId != "root" && file.parents != [folderId] {
                    print("FAIL: parents should be [\(folderId)]")
                    return 1
                }
                return 0
            } catch {
                sampler.cancel()
                printError(error)
                return 1
            }

        case .about:
            let service = drive()
            guard await restore(service) else { return 1 }
            do {
                let about = try await service.about()
                func text(_ bytes: Int64?) -> String {
                    guard let bytes else { return "unlimited" }
                    return "\(bytes) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
                }
                print("limit: \(text(about.limit))")
                print("usage: \(text(about.usage))")
                print("usageInDrive: \(text(about.usageInDrive))")
                print("trash: \(text(about.trash))")
                print("free: \(text(about.free))")
                print("account: \(about.user?.emailAddress ?? "-")")
                return 0
            } catch {
                printError(error)
                return 1
            }

        case .delete(let fileId):
            let service = drive()
            guard await restore(service) else { return 1 }
            do {
                try await service.deleteFile(id: fileId, protectedIds: Set(store.destinations.map(\.id)))
            } catch {
                printError(error)
                return 1
            }
            // it should be gone now
            do {
                let file = try await service.getFile(id: fileId)
                print("FAIL: \(file.id) is still there")
                return 1
            } catch let error as DriveError where error.category == .notFound {
                print("follow-up GET: 404, gone")
                return 0
            } catch {
                printError(error)
                return 1
            }

        case .listFolder(let folderId):
            let service = drive()
            guard await restore(service) else { return 1 }
            do {
                let files = try await service.listFolder(id: folderId)
                print("\(files.count) file(s) the app can see in \(folderId)")
                for file in files {
                    print("\(file.id)\t\(file.name)\t\(file.mimeType ?? "-")")
                }
                return 0
            } catch {
                printError(error)
                return 1
            }
        }
    }

    // restorePreviousSignIn calls back on main, so don't block main
    @MainActor
    private func restore(_ service: GoogleDriveService) async -> Bool {
        do {
            try await service.restorePreviousSignIn()
            return true
        } catch {
            print("sign-in restore failed")
            printError(error)
            // google sign-in hides keychain error -34018 behind "no sign-in" (-4)
            if !Self.hasKeychainEntitlement {
                print("unsigned build: press ⌘R in Xcode and use the DerivedData app")
            } else if (error as NSError).domain == "com.google.GIDSignIn" && (error as NSError).code == -4 {
                print("no saved sign-in: launch the app normally and sign in first")
            }
            return false
        }
    }

    // unsigned builds have no keychain-access-groups entitlement
    static var hasKeychainEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }

    private func printError(_ error: Error) {
        if let driveError = error as? DriveError {
            print("drive error: \(driveError.category.rawValue)")
            if let status = driveError.status { print("  status: \(status)") }
            if let reason = driveError.reason { print("  reason: \(reason)") }
            if let message = driveError.message { print("  message: \(message)") }
        } else {
            let nsError = error as NSError
            print("error: \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
        }
    }
}
