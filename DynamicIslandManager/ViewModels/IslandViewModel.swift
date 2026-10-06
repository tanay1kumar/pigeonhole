import SwiftUI
import Combine

// a result, shown in place of the tiles
struct IslandStatus: Equatable {
    enum Kind: Equatable {
        case success
    }

    let kind: Kind
    let message: String
}

@MainActor
class IslandViewModel: ObservableObject {
    // how long things stay up, tests shrink these
    struct Timing {
        var resultLinger: Double = 3    // success/error text, then the island may close
        var unattended: Double = 30     // a card nobody looks at folds away
        var parkRecheck: Double = 1     // pointer still over the island, check again
        var undoWindow: Double = 5      // how long "Sent [Undo]" stays
    }

    // state vars
    @Published var currentState: IslandState = .collapsed
    // the open commits the shape alone and the content a moment later, so the shape moves at once
    @Published private(set) var contentMounted = false
    @Published var surface: IslandSurface = .home
    // a finder drag shows the drop zone, it stays a moment after the drag ends
    @Published private(set) var showsDropZone = false
    // the notch the island grows from, set by the window
    @Published var islandScreen: IslandScreen?
    #if DEBUG
    // the reduce motion check turns this on, the real setting can't be changed from code
    @Published var debugReduceMotion = false
    #endif
    @Published private(set) var status: IslandStatus? {
        didSet {
            if status != oldValue {
                Self.signpostUntilCommit("contentSwap")
            }
        }
    }
    @Published private(set) var statusPinned = false
    @Published var authExpired = false
    @Published var parked = false

    // suggestion card, any change lets a parked island open again
    @Published var cardState: CardState = .idle {
        didSet {
            if cardState != oldValue {
                parked = false
                Self.signpostUntilCommit("contentSwap")
            }
        }
    }
    @Published var suggestions: [FileSuggestion] = []
    @Published var cardNote: String?          // "Couldn't read 1 file"
    @Published var sentSummary: String?       // "Sent to Resumes"
    @Published var justUploadProgress: Double?    // the one upload "just upload" makes, 0 to 1

    // card bookkeeping (IslandCard.swift)
    var featuresById: [UUID: FileFeatures] = [:]
    var cardGeneration = 0                    // bumped by clearCard so drops still loading for an old card get ignored
    var isFileDragging = false                // a finder drag hides the card behind the drop zone
    var classifyTasks: [Task<Void, Never>] = []
    var undoTask: Task<Void, Never>?
    var batchId: UUID?
    var deletedIds: Set<String> = []
    var lastSendWasSendAll = false
    var lastDropToRank: Double?
    var lastDropLoad: Double?                 // of that, ms until the dropped files could be read
    var dragStartedAt: Date?
    var lastDropAt: Date?
    var memoryLogTask: Task<Void, Never>?      // "60 s after classifying", once per quiet spell
    var dropZoneTask: Task<Void, Never>?
    // running uploads, so a row's x or the card's can stop them
    var uploadTasks: [UUID: Task<DriveFile, Error>] = [:]
    var justUploadTask: Task<Void, Never>?
    // the last "just upload", for logs and the scenario cleanup
    var lastUploadedFile: DriveFile?

    // a card or a pinned status keeps the island open, unless it was parked
    var holdsExpanded: Bool {
        (cardState != .idle || statusPinned) && !parked
    }

    // what nobody is looking at may fold away after a while
    var isUnattendedState: Bool {
        switch cardState {
        case .suggesting, .error: return true
        default: return false
        }
    }

    let driveService: DriveClient
    let destinationStore: DestinationStore
    let classifier: DestinationClassifier
    let extractor: FeatureExtractor
    var timing = Timing()
    // set by IslandHover, tells whether the pointer is over the expanded island
    var pointerIsOverIsland: () -> Bool = { false }

    private var statusTask: Task<Void, Never>?
    private var mountTask: Task<Void, Never>?
    var parkTask: Task<Void, Never>?
    private var signInObserver: AnyCancellable?
    private var destinationsObserver: AnyCancellable?

    init(driveService: DriveClient = GoogleDriveService(),
         destinationStore: DestinationStore = DestinationStore(),
         classifier: DestinationClassifier = DestinationClassifier(store: LearningStore(fileURL: nil)),
         extractor: FeatureExtractor = FeatureExtractor()) {
        self.driveService = driveService
        self.destinationStore = destinationStore
        self.classifier = classifier
        self.extractor = extractor

        // destinations edited while a card is open, rank its rows again
        destinationsObserver = destinationStore.$destinations
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.destinationsChanged()
                }
            }

        // sign-in worked again, the card stops offering it
        signInObserver = NotificationCenter.default.publisher(for: .didSignIn)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.signedIn()
                }
            }
    }

    // expand collapse, a passing drag opens it but a parked card stays parked
    // so it closes after the drag, only a hover brings the card back
    func expand(fromDrag: Bool = false) {
        var transaction = Transaction(animation: Motion.open)
        if currentState != .expanded {
            Self.signpostUntilCommit("expand")
            #if DEBUG
            DebugMotion.track(&transaction, "expand")
            #endif
            // a panel left open last time starts over at home, set here so it doesn't flash while fading out
            surface = .home
        }
        withTransaction(transaction) {
            currentState = .expanded
        }
        mountContentSoon()
        guard !fromDrag else { return }
        parked = false
        // count the unattended time again from now
        if isUnattendedState {
            scheduleParking()
        }
    }

    func collapse() {
        // every collapse path ends up here, a pinned status keeps the island open
        guard !holdsExpanded else { return }
        var transaction = Transaction(animation: Motion.close)
        if currentState != .collapsed {
            Self.signpostUntilCommit("collapse")
            #if DEBUG
            DebugMotion.track(&transaction, "collapse")
            #endif
        }
        mountTask?.cancel()
        mountTask = nil
        withTransaction(transaction) {
            currentState = .collapsed
            contentMounted = false
        }
    }

    // a refresh of the island's screen and a bit, a slow external screen needs longer than 20 ms
    var contentLag: Double {
        max(Motion.contentLag, (islandScreen?.refreshInterval ?? 0) + 0.004)
    }

    // building the content is most of an open's main-thread time, it waits a refresh so the shape moves first
    private func mountContentSoon() {
        guard !contentMounted, mountTask == nil else { return }
        let lag = contentLag
        mountTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lag))
            guard let self, !Task.isCancelled else { return }
            self.mountTask = nil
            guard self.isExpanded else { return }
            // the expand signpost ends at the shape's commit, this one times the content's
            Self.signpostUntilCommit("contentMount")
            withAnimation(Motion.content) {
                self.contentMounted = true
            }
        }
    }

    // main-thread time from now until swiftui has committed the change
    // points of interest is on outside instruments too, release pays a few us per change
    static func signpostUntilCommit(_ name: StaticString) {
        let signposter = Self.signposter
        #if !DEBUG
        guard signposter.isEnabled else { return }
        #endif
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        #if DEBUG
        let start = CACurrentMediaTime()
        #endif
        // after core animation's commit observer (order 2000000)
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, false, 2_100_000) { _, _ in
            signposter.endInterval(name, state)
            #if DEBUG
            let ms = (CACurrentMediaTime() - start) * 1000
            MainActor.assumeIsolated {
                DebugMotion.committed("\(name)", ms: ms)
            }
            #endif
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // MARK: what shows

    var isExpanded: Bool {
        currentState == .expanded
    }

    // drop zone first, then a card, a status, and the tiles or a panel
    var content: IslandContent {
        if showsDropZone { return .dropZone }
        if cardState != .idle { return .card }
        if status != nil { return .status }
        switch surface {
        case .home: return .home
        case .activity: return .activity
        case .storage: return .storage
        }
    }

    // the shape right now, the notch when closed and sized to its content when open
    var metrics: IslandMetrics {
        guard isExpanded else { return collapsedMetrics }
        return IslandMetrics(width: DesignConstants.expandedWidth, height: contentHeight,
                             bottomRadius: DesignConstants.expandedCornerRadius, earRadius: DesignConstants.earRadius)
    }

    // exactly the notch, nothing at all on a screen without one
    var collapsedMetrics: IslandMetrics {
        let notch = islandScreen?.notch ?? DesignConstants.fallbackNotch
        let visible = islandScreen?.hasNotch ?? true
        return IslandMetrics(width: notch.width, height: visible ? notch.height : 0,
                             bottomRadius: DesignConstants.notchCornerRadius, earRadius: 0)
    }

    // open height for what's showing
    var contentHeight: CGFloat {
        switch content {
        case .dropZone, .home: return DesignConstants.homeHeight
        case .status: return DesignConstants.statusHeight
        case .activity, .storage: return DesignConstants.expandedHeight
        case .card: return cardHeight
        }
    }

    private var cardHeight: CGFloat {
        switch cardState {
        case .idle:
            return DesignConstants.homeHeight
        case .classifying, .suggesting:
            // no rows yet while a drop loads, most drops are one file
            guard let row = suggestions.first else { return DesignConstants.singleCardHeight }
            guard suggestions.count == 1 else { return DesignConstants.expandedHeight }
            // every folder as chips can need more rows
            if row.status == .ready && row.level == .noIdea && destinationStore.destinations.count > 3 {
                return DesignConstants.expandedHeight
            }
            return DesignConstants.singleCardHeight
        case .sending:
            // just upload is one upload, a send lists its rows past one
            let rows = suggestions.filter {
                if case .failed = $0.status { return true }
                return $0.isSending || $0.isSent
            }
            return justUploadProgress != nil || rows.count <= 1 ? DesignConstants.statusHeight : DesignConstants.expandedHeight
        case .sent, .undoing:
            return DesignConstants.statusHeight
        case .error:
            let failed = suggestions.filter {
                if case .failed = $0.status { return true }
                return false
            }
            return failed.count > 1 ? DesignConstants.expandedHeight : DesignConstants.singleCardHeight
        }
    }

    // MARK: tiles

    func tileTapped(_ tile: Tile) {
        switch tile {
        case .activity: show(.activity)
        case .storage: show(.storage)
        case .settings: openSettings()
        }
    }

    // opens the island first if needed, the open resets to home
    func show(_ newSurface: IslandSurface) {
        if currentState == .collapsed {
            expand()
        }
        surface = newSurface
    }

    // the settings tile, the island gets out of the way
    func openSettings() {
        NotificationCenter.default.post(name: .showDestinationSetup, object: nil)
        collapse()
    }

    // the card without folders opens setup and keeps the card
    func chooseFolders() {
        NotificationCenter.default.post(name: .showDestinationSetup, object: nil)
    }

    // placeholders until activity and storage are built
    func tileContent(_ tile: Tile) -> TileContent {
        switch tile {
        case .activity: return TileContent(value: nil, caption: "No sends yet")
        case .storage: return TileContent(value: "–", caption: "Offline", ring: nil, dimmed: true)
        case .settings: return TileContent(value: nil, caption: "Settings")
        }
    }

    // a finder drag over the island, the drop zone goes a moment after it ends
    // so a drop landing as the drag ends still has its target
    func dropZoneChanged(_ dragging: Bool) {
        dropZoneTask?.cancel()
        dropZoneTask = nil
        if dragging {
            showsDropZone = true
            return
        }
        dropZoneTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.showsDropZone = false
            self.dropZoneTask = nil
        }
    }

    func requestSignIn() {
        NotificationCenter.default.post(name: .showSignIn, object: nil)
    }

    // MARK: status

    // pinned until replaced or cleared
    private func pin(_ newStatus: IslandStatus) {
        statusTask?.cancel()
        statusTask = nil
        parkTask?.cancel()
        parkTask = nil
        status = newStatus
        statusPinned = true
        parked = false
        if currentState == .collapsed {
            expand()
        }
    }

    // the card's "Just upload" ends with a result
    func showUploadResult(_ result: IslandStatus) {
        showResult(result)
    }

    // results stay up a few seconds, then the island may close again
    private func showResult(_ result: IslandStatus) {
        pin(result)
        let delay = timing.resultLinger
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            // judged against the result the user saw, before the tiles take its place
            let watched = self.pointerIsOverIsland()
            self.status = nil
            self.statusPinned = false
            self.statusTask = nil
            self.closeIfUnwatched(pointerWasOver: watched)
        }
    }

    // a card or result let go with the pointer away, close now so the tiles don't grow in first
    func closeIfUnwatched(pointerWasOver watched: Bool) {
        guard isExpanded, !holdsExpanded, !isFileDragging, !watched else { return }
        collapse()
    }

    private func signedIn() {
        guard authExpired else { return }
        authExpired = false
        parkTask?.cancel()
        parkTask = nil
        // a card nobody is looking at still folds away
        if isUnattendedState {
            scheduleParking()
        }
        print("signed in again")
    }

    #if DEBUG
    // tests check that a close stops the mount still waiting
    var debugMountTask: Task<Void, Never>? { mountTask }

    // scenarios start each run from a clean island
    func debugResetStatus() {
        statusTask?.cancel()
        parkTask?.cancel()
        status = nil
        statusPinned = false
        parked = false
        authExpired = false
    }
    #endif

    // unwatched cards fold away, hovering the notch brings them back
    func scheduleParking() {
        parkTask?.cancel()
        let delay = timing.unattended
        let recheck = timing.parkRecheck
        parkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            while let self, !Task.isCancelled, self.pointerIsOverIsland() {
                try? await Task.sleep(for: .seconds(recheck))
            }
            guard let self, !Task.isCancelled, self.isUnattendedState else { return }
            print("island unattended, parking")
            self.parked = true
            self.collapse()
            self.parkTask = nil
        }
    }
}
