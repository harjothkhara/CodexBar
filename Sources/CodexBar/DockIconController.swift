import AppKit
import CodexBarCore

struct DockIconWindowDescriptor: Equatable, Sendable {
    let identifier: String?
    let frameAutosaveName: String
    let title: String
    let classNames: [String]
    let width: Double
    let height: Double
    let isVisible: Bool
    let isMiniaturized: Bool
    let canBecomeKey: Bool
    let isKnownSettingsWindow: Bool

    var isSettingsWindow: Bool {
        self.isKnownSettingsWindow || self.identifier == SettingsWindowIdentity.identifier
    }

    var isPlaceholderSettingsWindow: Bool {
        PlaceholderSettingsWindowDecision.shouldClose(
            identifier: self.identifier,
            frameAutosaveName: self.frameAutosaveName,
            isKnownSettingsWindow: self.isKnownSettingsWindow)
    }

    var isSparkleWindow: Bool {
        !self.title.isEmpty && self.classNames.contains { className in
            className.contains("SPU") || className.contains("SUUpdate") || className.contains("Sparkle")
        }
    }

    var isRealWindow: Bool {
        guard !self.isPlaceholderSettingsWindow else { return false }
        guard self.isVisible, !self.isMiniaturized, self.canBecomeKey else { return false }
        guard !self.isTinyWindow, !self.isStatusBarWindow else { return false }
        return true
    }

    var isTinyWindow: Bool {
        self.width <= 20 && self.height <= 20
    }

    var isStatusBarWindow: Bool {
        self.classNames.contains { $0.contains("NSStatusBarWindow") }
    }

    @MainActor
    static func describe(_ window: NSWindow, isKnownSettingsWindow: Bool) -> Self {
        var classNames = [NSStringFromClass(type(of: window))]
        if let windowController = window.windowController {
            classNames.append(NSStringFromClass(type(of: windowController)))
        }
        if let contentViewController = window.contentViewController {
            classNames.append(NSStringFromClass(type(of: contentViewController)))
        }
        if let delegate = window.delegate {
            classNames.append(NSStringFromClass(type(of: delegate)))
        }

        return Self(
            identifier: window.identifier?.rawValue,
            frameAutosaveName: window.frameAutosaveName,
            title: window.title,
            classNames: classNames,
            width: window.frame.width,
            height: window.frame.height,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            canBecomeKey: window.canBecomeKey,
            isKnownSettingsWindow: isKnownSettingsWindow)
    }
}

enum DockIconPolicyDecision {
    static func shouldUseRegularActivationPolicy(windows: [DockIconWindowDescriptor]) -> Bool {
        windows.contains { window in
            window.isRealWindow || (window.isSettingsWindow && window.isMiniaturized)
        }
    }

    static func shouldPromoteForPresentedWindow(_ window: DockIconWindowDescriptor) -> Bool {
        window.isVisible && !window.isPlaceholderSettingsWindow && (window.isSettingsWindow || window.isSparkleWindow)
    }

    /// Windows that became eligible for Dock promotion since the last evaluation.
    static func newlyPresentedWindowIDs(
        current: Set<ObjectIdentifier>,
        previous: Set<ObjectIdentifier>)
        -> Set<ObjectIdentifier>
    {
        current.subtracting(previous)
    }
}

enum DockIconPresentationAttemptDecision: Equatable {
    case inactive
    case awaiting
    case presented
    case timedOut

    static func resolve(
        isAwaiting: Bool,
        hasPresentedWindow: Bool,
        deadlineExpired: Bool)
        -> Self
    {
        guard isAwaiting else { return .inactive }
        if hasPresentedWindow {
            return .presented
        }
        return deadlineExpired ? .timedOut : .awaiting
    }
}

struct DockIconPresentationAttemptID: Equatable, Sendable {
    fileprivate let rawValue: UInt64
}

struct DockIconPresentationAttemptTracker: Equatable {
    private(set) var activeID: DockIconPresentationAttemptID?
    private var nextRawID: UInt64 = 0

    var isAwaiting: Bool {
        self.activeID != nil
    }

    mutating func begin() -> DockIconPresentationAttemptID {
        self.nextRawID &+= 1
        let id = DockIconPresentationAttemptID(rawValue: self.nextRawID)
        self.activeID = id
        return id
    }

    mutating func finish(_ id: DockIconPresentationAttemptID) -> Bool {
        guard self.activeID == id else { return false }
        self.activeID = nil
        return true
    }

    mutating func resolve(
        hasPresentedWindow: Bool,
        deadlineExpiredFor deadlineID: DockIconPresentationAttemptID?)
        -> DockIconPresentationAttemptDecision
    {
        guard let activeID else { return .inactive }
        if let deadlineID, deadlineID != activeID {
            return .awaiting
        }

        let decision = DockIconPresentationAttemptDecision.resolve(
            isAwaiting: true,
            hasPresentedWindow: hasPresentedWindow,
            deadlineExpired: deadlineID != nil)
        if decision == .presented || decision == .timedOut {
            self.activeID = nil
        }
        return decision
    }
}

struct DockIconWindowCandidate {
    let id: ObjectIdentifier
    let descriptor: DockIconWindowDescriptor
    let present: @MainActor () -> Void
}

@MainActor
struct DockIconActivationPolicyClient {
    var isRegular: @MainActor () -> Bool
    var setRegular: @MainActor () -> Bool
    var setAccessory: @MainActor () -> Bool
    var activate: @MainActor () -> Void

    static var live: Self {
        Self(
            isRegular: { NSApp.activationPolicy() == .regular },
            setRegular: { NSApp.setActivationPolicy(.regular) },
            setAccessory: { NSApp.setActivationPolicy(.accessory) },
            activate: { NSApp.activate(ignoringOtherApps: true) })
    }
}

@MainActor
final class DockIconController: NSObject {
    typealias WindowCandidatesProvider = @MainActor (_ settingsWindow: NSWindow?) -> [DockIconWindowCandidate]
    typealias ReevaluationScheduler = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void

    static let shared = DockIconController()
    private static let settingsPresentationTimeout: Duration = .seconds(2)

    /// Real window transitions that can change Dock eligibility. Do not observe `didUpdate`:
    /// AppKit posts it on every event-loop pass (and once per window), which rescans all windows
    /// continuously and keeps the app busy while idle (#4516).
    static let windowTransitionNotifications: [Notification.Name] = [
        // Ordered in or out, hidden, or covered: catches windows that appear without becoming key
        // (background Sparkle alerts) and windows ordered out without closing.
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didBecomeMainNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        // Closing windows are still visible while the notification is delivered; the scheduled
        // reevaluation runs after the close finishes.
        NSWindow.willCloseNotification,
        // App hide/unhide toggles every window's visibility, including already occluded ones.
        NSApplication.didHideNotification,
        NSApplication.didUnhideNotification,
    ]

    private var isStarted = false
    private var isManagingRegularPolicy = false
    private var isReevaluationScheduled = false
    private var presentationAttemptTracker = DockIconPresentationAttemptTracker()
    private var settingsPresentationAttemptID: DockIconPresentationAttemptID?
    private var presentedWindowIDs: Set<ObjectIdentifier> = []
    private weak var settingsWindow: NSWindow?
    private var presentationTimeoutTask: Task<Void, Never>?
    private let notificationCenter: NotificationCenter
    private let activationPolicy: DockIconActivationPolicyClient
    private let windowCandidates: WindowCandidatesProvider
    private let scheduleReevaluation: ReevaluationScheduler
    private let logger = CodexBarLog.logger(LogCategories.app)

    init(
        notificationCenter: NotificationCenter = .default,
        activationPolicy: DockIconActivationPolicyClient = .live,
        windowCandidates: @escaping WindowCandidatesProvider = DockIconController.liveWindowCandidates,
        scheduleReevaluation: @escaping ReevaluationScheduler = DockIconController.scheduleOnLaterTurn)
    {
        self.notificationCenter = notificationCenter
        self.activationPolicy = activationPolicy
        self.windowCandidates = windowCandidates
        self.scheduleReevaluation = scheduleReevaluation
        super.init()
    }

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true

        for name in Self.windowTransitionNotifications {
            self.notificationCenter.addObserver(
                self,
                selector: #selector(self.windowStateDidChange(_:)),
                name: name,
                object: nil)
        }

        // Windows (for example Sparkle's update window) may have been presented before observation began.
        self.setNeedsReevaluation()
    }

    @discardableResult
    func promote(presentationTimeout: Duration) -> DockIconPresentationAttemptID {
        self.presentationTimeoutTask?.cancel()
        let attemptID = self.presentationAttemptTracker.begin()
        self.ensureRegularPolicy(activate: true)
        self.presentationTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: presentationTimeout)
            } catch {
                return
            }
            self?.reevaluatePolicy(presentationDeadlineExpiredFor: attemptID)
        }
        return attemptID
    }

    /// Call when another component is about to order a window in (for example Sparkle's scheduled alert).
    /// The coalesced rescan runs on a later main-actor turn and fronts any newly presented window once.
    func windowsMayHaveChanged() {
        self.setNeedsReevaluation()
    }

    func prepareToOpenSettings() {
        self.settingsPresentationAttemptID = self.promote(
            presentationTimeout: Self.settingsPresentationTimeout)
    }

    func registerSettingsWindow(_ window: NSWindow) {
        SettingsWindowStageBehavior.applyCollectionBehavior(window)
        self.settingsWindow = window
    }

    func settingsWindowDidPresent(_ window: NSWindow) {
        guard self.settingsWindow === window else { return }
        self.reevaluatePolicy()
        self.settingsPresentationAttemptID = nil
    }

    func settingsWindowPresentationFailed() {
        guard let settingsPresentationAttemptID else { return }
        self.settingsPresentationAttemptID = nil
        self.finishPresentationAttempt(settingsPresentationAttemptID)
    }

    func finishPresentationAttempt(_ attemptID: DockIconPresentationAttemptID) {
        guard self.presentationAttemptTracker.finish(attemptID) else { return }
        self.presentationTimeoutTask?.cancel()
        self.presentationTimeoutTask = nil
        self.reevaluatePolicy()
    }

    @objc private func windowStateDidChange(_ notification: Notification) {
        _ = notification
        self.setNeedsReevaluation()
    }

    /// Coalesces bursts (for example one occlusion notification per window on hide) into a single
    /// scan on a later main-actor turn, after the triggering transition has finished.
    private func setNeedsReevaluation() {
        guard !self.isReevaluationScheduled else { return }
        self.isReevaluationScheduled = true
        self.scheduleReevaluation { [weak self] in
            guard let self else { return }
            self.isReevaluationScheduled = false
            self.reevaluatePolicy()
        }
    }

    private func reevaluatePolicy(
        presentationDeadlineExpiredFor attemptID: DockIconPresentationAttemptID? = nil)
    {
        let describedWindows = self.windowCandidates(self.settingsWindow)
        let presentedWindowIDs = Set(describedWindows.compactMap { item in
            DockIconPolicyDecision.shouldPromoteForPresentedWindow(item.descriptor) ? item.id : nil
        })
        // Capture the delta before updating stored state so we only key newly presented
        // dialogs. Fronting every eligible window can re-key Settings over a Sparkle alert.
        let newlyPresentedWindowIDs = DockIconPolicyDecision.newlyPresentedWindowIDs(
            current: presentedWindowIDs,
            previous: self.presentedWindowIDs)
        let hasNewPresentedWindow = !newlyPresentedWindowIDs.isEmpty
        self.presentedWindowIDs = presentedWindowIDs

        let presentationDecision = self.presentationAttemptTracker.resolve(
            hasPresentedWindow: !presentedWindowIDs.isEmpty,
            deadlineExpiredFor: attemptID)
        switch presentationDecision {
        case .presented:
            self.presentationTimeoutTask?.cancel()
            self.presentationTimeoutTask = nil
        case .timedOut:
            self.presentationTimeoutTask = nil
            self.logger.error("Timed out waiting for a presented window; restoring accessory activation policy")
        case .inactive, .awaiting:
            break
        }

        if !presentedWindowIDs.isEmpty {
            self.ensureRegularPolicy(activate: hasNewPresentedWindow)
            if hasNewPresentedWindow {
                for item in describedWindows where newlyPresentedWindowIDs.contains(item.id) {
                    item.present()
                }
            }
        }

        guard self.isManagingRegularPolicy, !self.presentationAttemptTracker.isAwaiting else { return }
        let windows = describedWindows.map(\.descriptor)
        guard !DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: windows) else { return }

        if self.activationPolicy.setAccessory() {
            self.isManagingRegularPolicy = false
        }
    }

    private func ensureRegularPolicy(activate: Bool) {
        if !self.activationPolicy.isRegular(), self.activationPolicy.setRegular() {
            self.isManagingRegularPolicy = true
        }
        if activate {
            self.activationPolicy.activate()
        }
    }

    static func liveWindowCandidates(settingsWindow: NSWindow?) -> [DockIconWindowCandidate] {
        NSApp.windows.map { window in
            let descriptor = DockIconWindowDescriptor.describe(
                window,
                isKnownSettingsWindow: window === settingsWindow)
            return DockIconWindowCandidate(
                id: ObjectIdentifier(window),
                descriptor: descriptor,
                present: { [weak window] in
                    guard let window else { return }
                    if descriptor.isSettingsWindow {
                        SettingsWindowStageBehavior.present(window)
                    } else {
                        window.makeKeyAndOrderFront(nil)
                    }
                })
        }
    }

    static func scheduleOnLaterTurn(_ work: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            await Task.yield()
            work()
        }
    }

    deinit {
        self.presentationTimeoutTask?.cancel()
        self.notificationCenter.removeObserver(self)
    }
}
