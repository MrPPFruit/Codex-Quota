import AppKit
@testable import CodexUsageAccessory
import CodexUsageCore
import CodexUsageUI
import Foundation
import Testing

@MainActor
@Test func firstLaunchRegistrationIsAttemptedOnlyOnce() {
    let defaults = makeLifecycleDefaults()
    let service = LoginItemServiceSpy(status: .notRegistered)
    let controller = LoginItemController(service: service, defaults: defaults, allowsMutations: true)

    controller.prepareForLaunch()
    controller.prepareForLaunch()

    #expect(service.registerCount == 1)
    #expect(defaults.bool(forKey: LoginItemController.attemptedKey))
}

@Test func loginItemRequiresAStableApplicationsInstallation() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    #expect(LoginItemEligibility.isStableInstallation(
        bundleURL: URL(fileURLWithPath: "/Applications/Codex Quota.app"),
        bundleIdentifier: LoginItemEligibility.expectedBundleIdentifier,
        homeDirectory: home
    ))
    #expect(LoginItemEligibility.isStableInstallation(
        bundleURL: URL(fileURLWithPath: "/Users/tester/Applications/Codex Quota.app"),
        bundleIdentifier: LoginItemEligibility.expectedBundleIdentifier,
        homeDirectory: home
    ))
    #expect(LoginItemEligibility.isStableInstallation(
        bundleURL: URL(fileURLWithPath: "/Users/tester/Downloads/Codex Quota.app"),
        bundleIdentifier: LoginItemEligibility.expectedBundleIdentifier,
        homeDirectory: home
    ) == false)
    #expect(LoginItemEligibility.isStableInstallation(
        bundleURL: URL(fileURLWithPath: "/Users/tester/ApplicationsBackup/Codex Quota.app"),
        bundleIdentifier: LoginItemEligibility.expectedBundleIdentifier,
        homeDirectory: home
    ) == false)
    #expect(LoginItemEligibility.isStableInstallation(
        bundleURL: URL(fileURLWithPath: "/Applications/Codex Quota.app"),
        bundleIdentifier: "com.example.copy",
        homeDirectory: home
    ) == false)
}

@MainActor
@Test func userOptOutPreventsAutomaticReregistration() {
    let defaults = makeLifecycleDefaults()
    let service = LoginItemServiceSpy(status: .enabled)
    let controller = LoginItemController(service: service, defaults: defaults, allowsMutations: true)

    controller.performMenuAction()
    service.status = .notRegistered
    controller.prepareForLaunch()

    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 0)
    #expect(defaults.bool(forKey: LoginItemController.optOutKey))
}

@MainActor
@Test func previewAndSmokeModeCannotMutateLoginItem() {
    let defaults = makeLifecycleDefaults()
    let service = LoginItemServiceSpy(status: .notRegistered)
    let controller = LoginItemController(service: service, defaults: defaults, allowsMutations: false)

    controller.prepareForLaunch()
    controller.performMenuAction()

    #expect(service.registerCount == 0)
    #expect(service.unregisterCount == 0)
    #expect(service.openSettingsCount == 0)
    #expect(controller.presentation.isEnabled == false)
}

@MainActor
@Test func approvalStateOpensSettingsWithoutRegisteringAgain() {
    let service = LoginItemServiceSpy(status: .requiresApproval)
    let controller = LoginItemController(service: service, defaults: makeLifecycleDefaults(), allowsMutations: true)

    controller.performMenuAction()

    #expect(service.openSettingsCount == 1)
    #expect(service.registerCount == 0)
    #expect(controller.presentation.state == -1)
}

@MainActor
@Test func registrationFailureDoesNotPermanentlyDisableRecovery() {
    let service = LoginItemServiceSpy(status: .notRegistered, registerFailures: 1)
    let controller = LoginItemController(service: service, defaults: makeLifecycleDefaults(), allowsMutations: true)

    controller.prepareForLaunch()
    #expect(controller.presentation.title == "登录时启动（重试）")
    #expect(controller.presentation.isEnabled)

    service.status = .requiresApproval
    #expect(controller.presentation.title == "登录时启动（需要批准）")
    #expect(controller.presentation.isEnabled)
    controller.performMenuAction()
    #expect(service.openSettingsCount == 1)
}

@MainActor
@Test func unregisterFailureCanBeRetriedWithoutLosingUserIntent() {
    let defaults = makeLifecycleDefaults()
    let service = LoginItemServiceSpy(status: .enabled, unregisterFailures: 1)
    let controller = LoginItemController(service: service, defaults: defaults, allowsMutations: true)

    controller.performMenuAction()
    #expect(controller.presentation.isEnabled)
    #expect(defaults.bool(forKey: LoginItemController.optOutKey))

    controller.performMenuAction()
    #expect(service.unregisterCount == 2)
}

@Test func codexPresenceUsesOnlyTheCanonicalBundleIdentifier() {
    #expect(CodexPresencePolicy.isRunning(bundleIdentifiers: [nil, "com.openai.codex"]))
    #expect(CodexPresencePolicy.isRunning(bundleIdentifiers: ["com.openai.chatgpt"]) == false)
    #expect(CodexPresencePolicy.isRunning(bundleIdentifiers: ["Codex"]) == false)
}

@MainActor
@Test func systemPresenceMonitoringStartAndStopAreIdempotent() {
    let monitor = SystemCodexPresenceMonitor()
    monitor.start { _ in }
    monitor.start { _ in }
    #expect(monitor.isMonitoring)
    monitor.stop()
    monitor.stop()
    #expect(monitor.isMonitoring == false)
}

@Test func overlayVisibilityDefaultsOnAndPersistsOptOut() throws {
    let defaults = makeLifecycleDefaults()
    let store = UserDefaultsOverlayVisibilityStore(defaults: defaults)
    #expect(store.load())
    store.save(false)
    #expect(UserDefaultsOverlayVisibilityStore(defaults: defaults).load() == false)
}

@MainActor
@Test func lifecyclePauseStopsAndRestartRestoresOverlayMonitoring() {
    let window = LifecycleOverlayWindowSpy()
    let monitoringFactory = LifecycleMonitoringFactory()
    let overlay = OverlayController(
        window: window,
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        monitoringFactory: { action in monitoringFactory.make(action: action) }
    )
    overlay.show()

    overlay.setLifecycleAvailable(false)
    overlay.setLifecycleAvailable(false)
    overlay.setLifecycleAvailable(true)
    overlay.setLifecycleAvailable(true)

    #expect(monitoringFactory.monitors.count == 2)
    #expect(monitoringFactory.monitors[0].cancelCount == 1)
    #expect(window.outCount >= 1)
    #expect(window.frontCount >= 2)
}

@MainActor
@Test func codexRestartWaitsForOldSessionShutdownBeforeCreatingNewSession() async throws {
    let firstClient = LifecycleUsageClient(blocksClose: true)
    let secondClient = LifecycleUsageClient(blocksClose: false)
    let factory = LifecycleSessionFactory(clients: [firstClient, secondClient])
    let store = UsageStore()
    let overlay = OverlayController(
        window: LifecycleOverlayWindowSpy(),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )
    let coordinator = AccessoryLifecycleCoordinator(
        store: store,
        overlayController: overlay,
        sessionFactory: { publish in factory.make(publish: publish) }
    )

    coordinator.setCodexRunning(true)
    try await eventuallyLifecycle { factory.createdCount == 1 && coordinator.phase == .running }
    coordinator.setCodexRunning(false)
    try await eventuallyLifecycle { await firstClient.closeEntered }
    coordinator.setCodexRunning(true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(factory.createdCount == 1)

    await firstClient.yield(UsageSnapshot(
        fiveHour: UsageWindow(kind: .fiveHour, remainingPercent: 99, resetsAt: nil, freshness: .fresh),
        weekly: UsageWindow(kind: .weekly, remainingPercent: nil, resetsAt: nil, freshness: .unavailable)
    ))
    try await Task.sleep(for: .milliseconds(10))
    #expect(store.snapshot == .unavailable)

    await firstClient.releaseClose()
    try await eventuallyLifecycle { factory.createdCount == 2 && coordinator.phase == .running }
    try await coordinator.shutdownForQuit()
}

@MainActor
@Test func sameRunLoopAbsenceStillRecyclesTheRunningSession() async throws {
    let firstClient = LifecycleUsageClient(blocksClose: false)
    let secondClient = LifecycleUsageClient(blocksClose: false)
    let factory = LifecycleSessionFactory(clients: [firstClient, secondClient])
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: OverlayController(
            window: LifecycleOverlayWindowSpy(),
            visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
            startsMonitoring: false
        ),
        sessionFactory: { publish in factory.make(publish: publish) }
    )

    coordinator.setCodexRunning(true)
    try await eventuallyLifecycle { coordinator.phase == .running }
    coordinator.setCodexRunning(false)
    coordinator.setCodexRunning(true)

    try await eventuallyLifecycle { factory.createdCount == 2 && coordinator.phase == .running }
    #expect(await firstClient.closeCount == 1)
    try await coordinator.shutdownForQuit()
}

@MainActor
@Test func codexAbsentDoesNotCreateUsageSession() async throws {
    let factory = LifecycleSessionFactory(clients: [LifecycleUsageClient(blocksClose: false)])
    let overlay = OverlayController(
        window: LifecycleOverlayWindowSpy(),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: overlay,
        sessionFactory: { publish in factory.make(publish: publish) }
    )

    coordinator.setCodexRunning(false)
    try await Task.sleep(for: .milliseconds(20))

    #expect(factory.createdCount == 0)
    #expect(coordinator.phase == .idle)
}

@MainActor
@Test func missingSessionFactoryResultDoesNotBusyLoop() async throws {
    let factory = LifecycleSessionFactory(clients: [])
    let overlay = OverlayController(
        window: LifecycleOverlayWindowSpy(),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: overlay,
        sessionFactory: { publish in factory.make(publish: publish) }
    )

    coordinator.setCodexRunning(true)
    try await Task.sleep(for: .milliseconds(30))

    #expect(factory.attemptCount == 1)
    #expect(coordinator.phase == .starting)
    coordinator.setCodexRunning(false)
    try await eventuallyLifecycle { coordinator.phase == .idle }
}

@MainActor
@Test func missingSessionFactoryResultRetriesWhileCodexRemainsPresent() async throws {
    let client = LifecycleUsageClient(blocksClose: false)
    let factory = LifecycleSessionFactory(optionalClients: [nil, client])
    let overlay = OverlayController(
        window: LifecycleOverlayWindowSpy(),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: overlay,
        sessionFactory: { publish in factory.make(publish: publish) },
        retryDelay: { _ in await Task.yield() }
    )

    coordinator.setCodexRunning(true)
    try await eventuallyLifecycle { factory.attemptCount == 2 && coordinator.phase == .running }
    try await coordinator.shutdownForQuit()
}

@MainActor
@Test func codexExitCancelsPendingStartRetry() async throws {
    let factory = LifecycleSessionFactory(clients: [])
    let retryGate = LifecycleRetryGate()
    let overlay = OverlayController(
        window: LifecycleOverlayWindowSpy(),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: overlay,
        sessionFactory: { publish in factory.make(publish: publish) },
        retryDelay: { _ in await retryGate.waitUntilCancelled() }
    )

    coordinator.setCodexRunning(true)
    try await eventuallyLifecycle { await retryGate.entered }
    coordinator.setCodexRunning(false)
    try await eventuallyLifecycle { await retryGate.cancelled && coordinator.phase == .idle }
    #expect(factory.attemptCount == 1)
}

@MainActor
@Test func explicitQuitCancelsPendingStartRetry() async throws {
    let retryGate = LifecycleRetryGate()
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: OverlayController(
            window: LifecycleOverlayWindowSpy(),
            visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
            startsMonitoring: false
        ),
        sessionFactory: { _ in nil },
        retryDelay: { _ in await retryGate.waitUntilCancelled() }
    )

    coordinator.setCodexRunning(true)
    try await eventuallyLifecycle { await retryGate.entered }
    try await coordinator.shutdownForQuit()

    #expect(await retryGate.cancelled)
    #expect(coordinator.phase == .idle)
}

@MainActor
@Test func cleanupFailureBlocksReplacementSession() async throws {
    let failingClient = LifecycleUsageClient(blocksClose: false, closeFailures: 1)
    let replacement = LifecycleUsageClient(blocksClose: false)
    let factory = LifecycleSessionFactory(clients: [failingClient, replacement])
    let overlay = OverlayController(
        window: LifecycleOverlayWindowSpy(),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: overlay,
        sessionFactory: { publish in factory.make(publish: publish) }
    )

    coordinator.setCodexRunning(true)
    try await eventuallyLifecycle { coordinator.phase == .running }
    coordinator.setCodexRunning(false)
    try await eventuallyLifecycle { coordinator.phase == .degraded }
    coordinator.setCodexRunning(true)
    try await Task.sleep(for: .milliseconds(20))

    #expect(factory.createdCount == 1)
    #expect(coordinator.phase == .degraded)

    try await coordinator.shutdownForQuit()
    #expect(coordinator.phase == .idle)
    #expect(await failingClient.closeCount == 2)
}

@MainActor
@Test func cancelledStartingCandidateCleanupCanBeRetriedOnQuit() async throws {
    let gate = LifecycleFactoryGate()
    let client = LifecycleUsageClient(blocksClose: false, closeFailures: 1)
    let coordinator = AccessoryLifecycleCoordinator(
        store: UsageStore(),
        overlayController: OverlayController(
            window: LifecycleOverlayWindowSpy(),
            visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
            startsMonitoring: false
        ),
        sessionFactory: { publish in
            await gate.wait()
            return AccessoryUsageSession(client: client, publishSnapshot: publish)
        }
    )

    coordinator.setCodexRunning(true)
    try await eventuallyLifecycle { await gate.entered }
    coordinator.setCodexRunning(false)
    await gate.release()
    try await eventuallyLifecycle { coordinator.phase == .degraded }

    try await coordinator.shutdownForQuit()
    #expect(coordinator.phase == .idle)
    #expect(await client.closeCount == 2)
}

@MainActor
private final class LoginItemServiceSpy: LoginItemServicing {
    var status: LoginItemStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0
    private var registerFailures: Int
    private var unregisterFailures: Int

    init(status: LoginItemStatus, registerFailures: Int = 0, unregisterFailures: Int = 0) {
        self.status = status
        self.registerFailures = registerFailures
        self.unregisterFailures = unregisterFailures
    }
    func register() throws {
        registerCount += 1
        if registerFailures > 0 {
            registerFailures -= 1
            throw TestLifecycleError.expected
        }
    }
    func unregister() throws {
        unregisterCount += 1
        if unregisterFailures > 0 {
            unregisterFailures -= 1
            throw TestLifecycleError.expected
        }
    }
    func openSystemSettings() { openSettingsCount += 1 }
}

@MainActor
private final class LifecycleOverlayWindowSpy: OverlayWindowControlling {
    private(set) var frontCount = 0
    private(set) var outCount = 0
    func applyFrame(_ frame: NSRect, animated: Bool) {}
    func orderFrontRegardless() { frontCount += 1 }
    func orderOut() { outCount += 1 }
}

@MainActor
private final class LifecycleMonitoringSpy: OverlayMonitoring {
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class LifecycleMonitoringFactory {
    private(set) var monitors: [LifecycleMonitoringSpy] = []
    func make(action: @escaping @MainActor () -> Void) -> any OverlayMonitoring {
        let monitor = LifecycleMonitoringSpy()
        monitors.append(monitor)
        return monitor
    }
}

private actor LifecycleUsageClient: UsageStreamingClient {
    private let blocksClose: Bool
    private var closeFailures: Int
    private var continuation: AsyncStream<UsageSnapshot>.Continuation?
    private var closeGate: CheckedContinuation<Void, Never>?
    private(set) var closeEntered = false
    private(set) var closeCount = 0

    init(blocksClose: Bool, closeFailures: Int = 0) {
        self.blocksClose = blocksClose
        self.closeFailures = closeFailures
    }

    func snapshots() -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.unavailable)
        }
    }

    func start() async throws -> UsageSnapshot { .unavailable }
    func reconnect() async throws -> UsageSnapshot { .unavailable }

    func close() async throws {
        closeEntered = true
        closeCount += 1
        if blocksClose { await withCheckedContinuation { closeGate = $0 } }
        if closeFailures > 0 {
            closeFailures -= 1
            throw AppServerClientError.cleanupFailure
        }
        continuation?.finish()
    }

    func yield(_ snapshot: UsageSnapshot) { continuation?.yield(snapshot) }

    func releaseClose() {
        closeGate?.resume()
        closeGate = nil
    }
}

private actor LifecycleFactoryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LifecycleRetryGate {
    private(set) var entered = false
    private(set) var cancelled = false

    func waitUntilCancelled() async {
        entered = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancelled = true
        }
    }
}

private enum TestLifecycleError: Error { case expected }

@MainActor
private final class LifecycleSessionFactory {
    private var clients: [LifecycleUsageClient?]
    private(set) var createdCount = 0
    private(set) var attemptCount = 0

    init(clients: [LifecycleUsageClient]) { self.clients = clients.map(Optional.some) }
    init(optionalClients: [LifecycleUsageClient?]) { self.clients = optionalClients }

    func make(
        publish: @escaping @MainActor (UsageSnapshot) -> Void
    ) -> AccessoryUsageSession? {
        attemptCount += 1
        guard !clients.isEmpty else { return nil }
        guard let client = clients.removeFirst() else { return nil }
        createdCount += 1
        return AccessoryUsageSession(client: client, publishSnapshot: publish)
    }
}

private func makeLifecycleDefaults() -> UserDefaults {
    let suite = "CodexQuotaLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
private func eventuallyLifecycle(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("lifecycle condition did not become true")
}
