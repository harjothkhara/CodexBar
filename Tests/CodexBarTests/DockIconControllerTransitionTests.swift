import AppKit
import Testing
@testable import CodexBar

@MainActor
struct DockIconControllerTransitionTests {
    @Test
    func `didUpdate notifications never schedule a window rescan`() {
        let harness = Harness()
        harness.windows = [harness.sparkle(isVisible: true)]
        harness.controller.start()
        harness.scheduler.runAll()
        let scheduledAfterSeed = harness.scheduler.scheduledCount
        let scansAfterSeed = harness.scanCount
        harness.windows = []
        harness.policy.isRegular = false

        for _ in 0..<50 {
            harness.center.post(name: NSApplication.didUpdateNotification, object: nil)
            harness.center.post(name: NSWindow.didUpdateNotification, object: nil)
        }
        harness.scheduler.runAll()

        #expect(harness.scheduler.scheduledCount == scheduledAfterSeed)
        #expect(harness.scanCount == scansAfterSeed)
        #expect(!harness.policy.isRegular)
    }

    @Test
    func `windows visible before start are promoted by the seed scan`() {
        let sparkleHarness = Harness()
        let sparkle = sparkleHarness.sparkle(isVisible: true)
        sparkleHarness.windows = [sparkle]
        sparkleHarness.controller.start()
        #expect(!sparkleHarness.policy.isRegular)
        sparkleHarness.scheduler.runAll()
        #expect(sparkleHarness.policy.isRegular)
        #expect(sparkleHarness.presentedIDs == [sparkle.id])

        let settingsHarness = Harness()
        let settings = settingsHarness.settings(isVisible: true)
        settingsHarness.windows = [settings]
        settingsHarness.controller.start()
        settingsHarness.scheduler.runAll()
        #expect(settingsHarness.policy.isRegular)
        #expect(settingsHarness.presentedIDs == [settings.id])
    }

    @Test
    func `starting twice seeds only one rescan`() {
        let harness = Harness()
        harness.controller.start()
        harness.controller.start()
        #expect(harness.scheduler.scheduledCount == 1)
        harness.scheduler.runAll()
        harness.controller.start()
        #expect(harness.scheduler.scheduledCount == 1)
        #expect(harness.scanCount == 1)
    }

    @Test
    func `observed notifications are window transitions only`() {
        let names = Set(DockIconController.windowTransitionNotifications)

        #expect(names == [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ])
        #expect(!names.contains(NSApplication.didUpdateNotification))
        #expect(!names.contains(NSWindow.didUpdateNotification))
    }

    @Test
    func `a burst of window transitions coalesces into one rescan`() {
        let harness = Harness()
        harness.controller.start()

        for name in DockIconController.windowTransitionNotifications {
            harness.center.post(name: name, object: nil)
            harness.center.post(name: name, object: nil)
        }
        #expect(harness.scheduler.pendingCount == 1)
        #expect(harness.scanCount == 0)
        harness.scheduler.runAll()
        #expect(harness.scanCount == 1)

        harness.center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(harness.scheduler.pendingCount == 1)
        harness.scheduler.runAll()
        #expect(harness.scanCount == 2)
    }

    @Test
    func `Sparkle window shown without becoming key promotes and fronts it once`() {
        let harness = Harness()
        let sparkle = harness.sparkle(isVisible: true)
        harness.windows = [sparkle]
        harness.controller.start()

        harness.post(NSWindow.didChangeOcclusionStateNotification)

        #expect(harness.policy.isRegular)
        #expect(harness.policy.activateCount == 1)
        #expect(harness.presentedIDs == [sparkle.id])

        harness.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(harness.policy.isRegular)
        #expect(harness.presentedIDs == [sparkle.id])
    }

    @Test
    func `Settings window becoming key or main promotes it`() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            let harness = Harness()
            let settings = harness.settings(isVisible: true)
            harness.windows = [settings]
            harness.controller.start()

            harness.post(name)

            #expect(harness.policy.isRegular)
            #expect(harness.presentedIDs == [settings.id])
        }
    }

    @Test
    func `Sparkle window ordered out without closing demotes on occlusion change`() {
        let harness = Harness()
        harness.windows = [harness.sparkle(isVisible: true)]
        harness.controller.start()
        harness.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(harness.policy.isRegular)

        harness.windows = [harness.sparkle(isVisible: false)]
        harness.post(NSWindow.didChangeOcclusionStateNotification)

        #expect(!harness.policy.isRegular)
    }

    @Test
    func `closing Settings demotes on the turn after it closes`() {
        let harness = Harness()
        harness.windows = [harness.settings(isVisible: true)]
        harness.controller.start()
        harness.post(NSWindow.didBecomeKeyNotification)
        #expect(harness.policy.isRegular)

        harness.center.post(name: NSWindow.willCloseNotification, object: nil)
        #expect(harness.policy.isRegular)
        harness.windows = [harness.settings(isVisible: false)]
        harness.scheduler.runAll()

        #expect(!harness.policy.isRegular)
    }

    @Test
    func `miniaturizing Sparkle demotes and deminiaturizing promotes again`() {
        let harness = Harness()
        let sparkle = harness.sparkle(isVisible: true)
        harness.windows = [sparkle]
        harness.controller.start()
        harness.post(NSWindow.didBecomeKeyNotification)

        harness.windows = [harness.sparkle(isVisible: false, isMiniaturized: true)]
        harness.post(NSWindow.didMiniaturizeNotification)
        #expect(!harness.policy.isRegular)

        harness.windows = [sparkle]
        harness.post(NSWindow.didDeminiaturizeNotification)
        #expect(harness.policy.isRegular)
        #expect(harness.presentedIDs == [sparkle.id, sparkle.id])
    }

    @Test
    func `miniaturized Settings keeps the Dock icon`() {
        let harness = Harness()
        harness.windows = [harness.settings(isVisible: true)]
        harness.controller.start()
        harness.post(NSWindow.didBecomeKeyNotification)

        harness.windows = [harness.settings(isVisible: false, isMiniaturized: true)]
        harness.post(NSWindow.didMiniaturizeNotification)

        #expect(harness.policy.isRegular)
    }

    @Test
    func `hiding the app demotes and unhiding promotes again`() {
        let harness = Harness()
        let settings = harness.settings(isVisible: true)
        harness.windows = [settings]
        harness.controller.start()
        harness.post(NSWindow.didBecomeKeyNotification)

        harness.windows = [harness.settings(isVisible: false)]
        harness.post(NSApplication.didHideNotification)
        #expect(!harness.policy.isRegular)

        harness.windows = [settings]
        harness.post(NSApplication.didUnhideNotification)
        #expect(harness.policy.isRegular)
    }

    @Test
    func `Settings promotion is immediate and a failed presentation demotes explicitly`() {
        let harness = Harness()
        harness.controller.start()
        harness.scheduler.runAll()
        let scansAfterSeed = harness.scanCount
        let scheduledAfterSeed = harness.scheduler.scheduledCount

        harness.controller.prepareToOpenSettings()
        #expect(harness.policy.isRegular)
        #expect(harness.policy.activateCount == 1)
        #expect(harness.scanCount == scansAfterSeed)

        harness.controller.settingsWindowPresentationFailed()
        #expect(harness.scanCount == scansAfterSeed + 1)
        #expect(!harness.policy.isRegular)
        #expect(harness.scheduler.scheduledCount == scheduledAfterSeed)
    }

    @Test
    func `awaiting presentation keeps the Dock until the presented window goes away`() {
        let harness = Harness()
        harness.controller.start()
        harness.controller.promote(presentationTimeout: .seconds(60))

        harness.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(harness.policy.isRegular)

        let sparkle = harness.sparkle(isVisible: true)
        harness.windows = [sparkle]
        harness.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(harness.presentedIDs == [sparkle.id])

        harness.windows = [harness.sparkle(isVisible: false)]
        harness.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(!harness.policy.isRegular)
    }

    @Test
    func `finishing an update attempt without a window demotes explicitly`() {
        let harness = Harness()
        harness.controller.start()
        let attempt = harness.controller.promote(presentationTimeout: .seconds(60))
        harness.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(harness.policy.isRegular)

        harness.controller.finishPresentationAttempt(attempt)

        #expect(!harness.policy.isRegular)
    }

    @Test
    func `default scheduler runs a coalesced rescan on a later turn`() async {
        let center = NotificationCenter()
        var scanCount = 0
        let controller = DockIconController(
            notificationCenter: center,
            activationPolicy: Harness.FakeActivationPolicy().client,
            windowCandidates: { _ in
                scanCount += 1
                return []
            })
        controller.start()

        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        #expect(scanCount == 0)

        let deadline = ContinuousClock.now + .seconds(5)
        while scanCount == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(scanCount == 1)
    }

    @Test
    func `presentation timeout demotes when no window appears`() async {
        let harness = Harness()
        harness.controller.start()
        harness.scheduler.runAll()
        let scheduledAfterSeed = harness.scheduler.scheduledCount
        harness.controller.promote(presentationTimeout: .milliseconds(1))
        #expect(harness.policy.isRegular)

        let deadline = ContinuousClock.now + .seconds(5)
        while harness.policy.isRegular, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(!harness.policy.isRegular)
        #expect(harness.scheduler.scheduledCount == scheduledAfterSeed)
    }
}

// MARK: - Harness

@MainActor
private final class Harness {
    final class Token {}

    @MainActor
    final class FakeActivationPolicy {
        var isRegular = false
        var activateCount = 0

        var client: DockIconActivationPolicyClient {
            DockIconActivationPolicyClient(
                isRegular: { self.isRegular },
                setRegular: {
                    self.isRegular = true
                    return true
                },
                setAccessory: {
                    self.isRegular = false
                    return true
                },
                activate: { self.activateCount += 1 })
        }
    }

    @MainActor
    final class ManualScheduler {
        private var pending: [@MainActor @Sendable () -> Void] = []
        private(set) var scheduledCount = 0

        var pendingCount: Int {
            self.pending.count
        }

        func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
            self.scheduledCount += 1
            self.pending.append(work)
        }

        func runAll() {
            while !self.pending.isEmpty {
                self.pending.removeFirst()()
            }
        }
    }

    struct Window {
        let id: ObjectIdentifier
        let descriptor: DockIconWindowDescriptor
    }

    let center = NotificationCenter()
    let policy = FakeActivationPolicy()
    let scheduler = ManualScheduler()
    var windows: [Window] = []
    private(set) var scanCount = 0
    private(set) var presentedIDs: [ObjectIdentifier] = []
    private let settingsToken = Token()
    private let sparkleToken = Token()

    lazy var controller = DockIconController(
        notificationCenter: self.center,
        activationPolicy: self.policy.client,
        windowCandidates: { [unowned self] _ in
            self.scanCount += 1
            return self.windows.map { window in
                DockIconWindowCandidate(
                    id: window.id,
                    descriptor: window.descriptor,
                    present: { [unowned self] in self.presentedIDs.append(window.id) })
            }
        },
        scheduleReevaluation: { [unowned self] work in self.scheduler.schedule(work) })

    func post(_ name: Notification.Name) {
        self.center.post(name: name, object: nil)
        self.scheduler.runAll()
    }

    func settings(isVisible: Bool, isMiniaturized: Bool = false) -> Window {
        Window(
            id: ObjectIdentifier(self.settingsToken),
            descriptor: Self.descriptor(
                title: "Settings",
                classNames: ["NSWindow"],
                isVisible: isVisible,
                isMiniaturized: isMiniaturized,
                isKnownSettingsWindow: true))
    }

    func sparkle(isVisible: Bool, isMiniaturized: Bool = false) -> Window {
        Window(
            id: ObjectIdentifier(self.sparkleToken),
            descriptor: Self.descriptor(
                title: "A new version is available",
                classNames: ["Sparkle.SPUStandardUserDriverWindowController"],
                isVisible: isVisible,
                isMiniaturized: isMiniaturized,
                isKnownSettingsWindow: false))
    }

    private static func descriptor(
        title: String,
        classNames: [String],
        isVisible: Bool,
        isMiniaturized: Bool,
        isKnownSettingsWindow: Bool)
        -> DockIconWindowDescriptor
    {
        DockIconWindowDescriptor(
            identifier: nil,
            frameAutosaveName: "",
            title: title,
            classNames: classNames,
            width: 600,
            height: 400,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            canBecomeKey: true,
            isKnownSettingsWindow: isKnownSettingsWindow)
    }
}
