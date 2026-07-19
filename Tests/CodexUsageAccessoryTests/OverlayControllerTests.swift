import AppKit
@testable import CodexUsageAccessory
import CodexUsageCore
import CodexUsageUI
import Testing

@MainActor
@Test func overlayWindowPolicyNeverActivates() {
    let policy = OverlayWindowPolicy.standard

    #expect(policy.styleMask.contains(.nonactivatingPanel))
    #expect(policy.level == .floating)
    #expect(policy.canBecomeKey == false)
    #expect(policy.canBecomeMain == false)
    #expect(policy.hidesOnDeactivate == false)
    #expect(policy.isMovable)
    #expect(policy.isMovableByWindowBackground)
    #expect(OverlayPanel.spaceCollectionBehavior.contains(.canJoinAllSpaces))
    #expect(OverlayPanel.spaceCollectionBehavior.contains(.fullScreenAuxiliary))
}

@Test func panelMoveClassifierSuppressesOnlyMatchingProgrammaticMove() {
    var classifier = OverlayPanelMoveClassifier()
    let expected = CGRect(x: 100, y: 200, width: 60, height: 60)
    classifier.recordProgrammaticFrame(expected)

    let matchingMove = classifier.isUserMove(expected.offsetBy(dx: 0.1, dy: -0.1))
    #expect(matchingMove == false)
    let unannouncedMove = classifier.isUserMove(expected)
    #expect(unannouncedMove)

    classifier.recordProgrammaticFrame(expected)
    let displacedMove = classifier.isUserMove(expected.offsetBy(dx: 20, dy: 0))
    #expect(displacedMove)
}

@Test func panelMoveClassifierSuppressesAnimatedFramesUntilMatchingCompletion() {
    var classifier = OverlayPanelMoveClassifier()
    let firstTarget = CGRect(x: 80, y: 90, width: 130, height: 78)
    let first = classifier.beginProgrammaticAnimation(to: firstTarget)
    #expect(classifier.isUserMove(CGRect(x: 100, y: 100, width: 80, height: 60)) == false)

    let secondTarget = CGRect(x: 120, y: 120, width: 52, height: 52)
    let second = classifier.beginProgrammaticAnimation(to: secondTarget)
    classifier.finishProgrammaticAnimation(first)
    #expect(classifier.isUserMove(CGRect(x: 110, y: 100, width: 70, height: 58)) == false)

    classifier.finishProgrammaticAnimation(second)
    #expect(classifier.isUserMove(secondTarget) == false)
    let realMove = classifier.isUserMove(CGRect(x: 120, y: 100, width: 60, height: 56))
    #expect(realMove)
}

@Test func userDragCanInterruptProgrammaticAnimation() {
    var classifier = OverlayPanelMoveClassifier()
    _ = classifier.beginProgrammaticAnimation(to: CGRect(x: 80, y: 90, width: 130, height: 78))
    let interruptedFrame = CGRect(x: 90, y: 95, width: 100, height: 66)
    classifier.interruptProgrammaticAnimation(at: interruptedFrame)

    let interruptionMove = classifier.isUserMove(interruptedFrame)
    #expect(interruptionMove == false)
    let draggedFrame = interruptedFrame.offsetBy(dx: 12, dy: -8)
    let userMove = classifier.isUserMove(draggedFrame)
    #expect(userMove)
}

@Test func overlaySizesMatchApprovedDesign() {
    #expect(OverlayLayout.collapsedSize == NSSize(width: 52, height: 52))
    #expect(OverlayLayout.expandedSize == NSSize(width: 130, height: 78))
}

@MainActor
@Test func hoverAppliesOnlyTheFinalExpandedFrame() {
    let window = OverlayWindowSpy()
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )

    controller.setHovered(true)

    #expect(window.sizes.isEmpty)
    #expect(window.frames == [CGRect(x: 622, y: 48, width: 130, height: 78)])
    #expect(window.animated == [true])
}

@MainActor
@Test func reduceMotionMakesHoverFrameImmediate() {
    let window = OverlayWindowSpy()
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )

    controller.setHovered(true, animated: false)

    #expect(window.frames == [CGRect(x: 622, y: 48, width: 130, height: 78)])
    #expect(window.animated == [false])
}

@MainActor
@Test func disabledPetAffinitySkipsSystemWindowEnumeration() {
    let provider = CountingWindowProvider()
    let controller = OverlayController(
        window: OverlayWindowSpy(),
        windowProvider: provider,
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(provider.readCount == 0)
}

@Test func overlayHitRegionPassesTransparentCornersThrough() {
    let collapsed = OverlayHitRegion(size: OverlayLayout.collapsedSize, cornerRadius: 26)
    #expect(collapsed.contains(NSPoint(x: 26, y: 26)))
    #expect(collapsed.contains(NSPoint(x: 1, y: 1)) == false)

    let expanded = OverlayHitRegion(size: OverlayLayout.expandedSize, cornerRadius: OverlayLayout.expandedCornerRadius)
    #expect(expanded.contains(NSPoint(x: 71, y: 39)))
    #expect(expanded.contains(NSPoint(x: 143, y: 79)) == false)
    #expect(expanded.contains(NSPoint(x: 1, y: 1)) == false)
}

@Test func hoverRetentionUsesEntryAndExpandedFramesWithSpatialMargin() {
    let entry = CGRect(x: 748, y: 548, width: 52, height: 52)
    let expanded = CGRect(x: 670, y: 522, width: 130, height: 78)

    let region = OverlayHoverPolicy.retentionRegion(entryFrame: entry, expandedFrame: expanded)

    #expect(region == CGRect(x: 660, y: 512, width: 150, height: 98))
    #expect(region.contains(CGPoint(x: 790, y: 590)))
    #expect(region.contains(CGPoint(x: 659, y: 590)) == false)
}

@MainActor
@Test func hoverExitWaitsForPointerToLeaveSpatialRetentionRegion() async throws {
    let window = OverlayWindowSpy()
    let expansionStore = OverlayExpansionStore()
    let pointer = MutablePointerLocation(CGPoint(x: 726, y: 74))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false,
        expansionStore: expansionStore,
        pointerLocation: { pointer.value },
        hoverPollInterval: .milliseconds(5)
    )
    controller.recalculatePlacement()

    controller.updateHover(true)
    controller.updateHover(false)
    try await Task.sleep(for: .milliseconds(20))
    #expect(expansionStore.isExpanded)

    pointer.value = CGPoint(x: -100, y: -100)
    for _ in 0..<20 where expansionStore.isExpanded {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(expansionStore.isExpanded == false)
    #expect(window.frames.last?.size == OverlayLayout.collapsedSize)
}

@MainActor
@Test func draggingExpandedOverlayRebasesHoverRetentionToItsNewLocation() async throws {
    let window = OverlayWindowSpy()
    let expansionStore = OverlayExpansionStore()
    let pointer = MutablePointerLocation(CGPoint(x: 726, y: 74))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false,
        expansionStore: expansionStore,
        pointerLocation: { pointer.value },
        hoverPollInterval: .milliseconds(5)
    )
    controller.recalculatePlacement()
    controller.updateHover(true)

    let draggedFrame = CGRect(x: 100, y: 100, width: 130, height: 78)
    controller.recordUserMove(draggedFrame)
    controller.recalculatePlacement()

    pointer.value = CGPoint(x: 235, y: 120)
    controller.updateHover(false)
    try await Task.sleep(for: .milliseconds(20))
    #expect(expansionStore.isExpanded)

    // This point is outside the dragged overlay's local retention margin, but
    // inside the obsolete union spanning its old and new locations.
    pointer.value = CGPoint(x: 400, y: 120)
    controller.updateHover(false)
    for _ in 0..<20 where expansionStore.isExpanded {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(expansionStore.isExpanded == false)
    #expect(window.frames.last == CGRect(x: 139, y: 113, width: 52, height: 52))
}

@Test func statusMenuPolicyKeepsVisibilityAndQuitActions() {
    #expect(StatusMenuPolicy.itemTitles == ["显示额度气泡", "退出"])
    #expect(StatusMenuPolicy.bubbleEffectTitle == "气泡效果")
}

@Test func statusItemIconUsesDualQuotaTracks() {
    #expect(StatusItemIconRenderer.fillWidth(remainingPercent: nil, maximumWidth: 13) == 0)
    #expect(StatusItemIconRenderer.fillWidth(remainingPercent: 0, maximumWidth: 13) == 0)
    #expect(StatusItemIconRenderer.fillWidth(remainingPercent: 50, maximumWidth: 13) == 6.5)
    #expect(StatusItemIconRenderer.fillWidth(remainingPercent: 100, maximumWidth: 13) == 13)
    #expect(StatusItemIconRenderer.fillWidth(remainingPercent: 120, maximumWidth: 13) == 13)
    #expect(StatusItemIconRenderer.fillWidth(remainingPercent: 1, maximumWidth: 13) == 0.13)
    #expect(StatusItemIconRenderer.weeklyMaximumWidth < StatusItemIconRenderer.fiveHourMaximumWidth)
    #expect(StatusItemIconRenderer.weeklyX > StatusItemIconRenderer.fiveHourX)

    let image = StatusItemIconRenderer.makeImage(fiveHourPercent: 80, weeklyPercent: 45)
    #expect(image.size == StatusItemIconRenderer.canvasSize)
    #expect(image.isTemplate)

    let lowImage = StatusItemIconRenderer.makeImage(fiveHourPercent: 1, weeklyPercent: 1)
    let unavailableImage = StatusItemIconRenderer.makeImage(fiveHourPercent: nil, weeklyPercent: nil)
    #expect(image.tiffRepresentation != lowImage.tiffRepresentation)
    #expect(lowImage.tiffRepresentation != unavailableImage.tiffRepresentation)
}

@Test func statusItemAccessibilityNamesBothQuotaWindows() {
    let snapshot = UsageSnapshot(
        fiveHour: UsageWindow(kind: .fiveHour, remainingPercent: 80, resetsAt: nil, freshness: .fresh),
        weekly: UsageWindow(kind: .weekly, remainingPercent: nil, resetsAt: nil, freshness: .unavailable)
    )

    #expect(StatusItemIconRenderer.accessibilityLabel(for: snapshot) == "Codex Quota，5小时剩余80%，本周剩余不可用")
}

@Test func smokeDiagnosticsRequireOwnedTemporaryDestinationAndBoundedExit() {
    let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    let validPath = temporaryRoot
        .appendingPathComponent("codex-accessory-smoke.tests")
        .appendingPathComponent("internal.json")
        .path

    #expect(SmokeDiagnostics.configuration(environment: [
        SmokeDiagnostics.pathVariable: validPath,
        SmokeDiagnostics.exitVariable: "3",
    ]) != nil)
    #expect(SmokeDiagnostics.configuration(environment: [
        SmokeDiagnostics.pathVariable: temporaryRoot.appendingPathComponent("unowned/internal.json").path,
        SmokeDiagnostics.exitVariable: "3",
    ]) == nil)
    #expect(SmokeDiagnostics.configuration(environment: [
        SmokeDiagnostics.pathVariable: validPath,
        SmokeDiagnostics.exitVariable: "11",
    ]) == nil)
    #expect(SmokeDiagnostics.configuration(environment: [
        SmokeDiagnostics.pathVariable: validPath,
    ]) == nil)
}

@Test func smokePresenceOverrideAcceptsOnlyExplicitStates() {
    #expect(SmokeDiagnostics.forcedCodexPresence(environment: [SmokeDiagnostics.codexPresenceVariable: "present"]) == true)
    #expect(SmokeDiagnostics.forcedCodexPresence(environment: [SmokeDiagnostics.codexPresenceVariable: "absent"]) == false)
    #expect(SmokeDiagnostics.forcedCodexPresence(environment: [SmokeDiagnostics.codexPresenceVariable: "unknown"]) == nil)
    #expect(SmokeDiagnostics.forcedCodexPresence(environment: [:]) == nil)
}

@MainActor
@Test func smokeDiagnosticsAtomicallyReplaceWithoutFollowingDestinationSymlink() async throws {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    let directory = root.appendingPathComponent("codex-accessory-smoke.\(UUID().uuidString)")
    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("internal.json")
    let outside = directory.appendingPathComponent("outside.json")
    try Data("outside".utf8).write(to: outside)
    try manager.createSymbolicLink(at: destination, withDestinationURL: outside)

    let panel = OverlayPanel()
    SmokeDiagnostics.write(to: destination, panel: panel, statusItemCount: 1, menuItemCount: 2, exitedThroughControlledPath: false)

    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    #expect((try manager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeRegular)
    #expect((try manager.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let first = try JSONDecoder().decode(SmokeDiagnostic.self, from: Data(contentsOf: destination))
    #expect(first.menuItemCount == 2)

    let reader = Task.detached {
        for _ in 0..<200 {
            guard let data = try? Data(contentsOf: destination),
                  let value = try? JSONDecoder().decode(SmokeDiagnostic.self, from: data),
                  value.menuItemCount == 1 || value.menuItemCount == 2
            else { return false }
        }
        return true
    }
    for index in 0..<40 {
        SmokeDiagnostics.write(to: destination, panel: panel, statusItemCount: 1, menuItemCount: index.isMultiple(of: 2) ? 1 : 2, exitedThroughControlledPath: false)
    }
    #expect(await reader.value)
    SmokeDiagnostics.write(to: destination, panel: panel, statusItemCount: 1, menuItemCount: 1, exitedThroughControlledPath: true)
    let second = try JSONDecoder().decode(SmokeDiagnostic.self, from: Data(contentsOf: destination))
    #expect(second.menuItemCount == 1)
    #expect(second.exitedThroughControlledPath)

    let directoryTarget = directory.appendingPathComponent("directory-target")
    try manager.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
    SmokeDiagnostics.write(to: directoryTarget, panel: panel, statusItemCount: 1, menuItemCount: 9, exitedThroughControlledPath: false)
    #expect((try manager.attributesOfItem(atPath: directoryTarget.path)[.type] as? FileAttributeType) == .typeDirectory)
}

@MainActor
@Test func shutdownClosesOnceBeforeEndingObservationEvenWhenStartHangs() async throws {
    let client = HangingUsageClient()
    let store = UsageStore()
    let session = AccessoryUsageSession(client: client, store: store)
    await session.start()
    try await eventuallyAccessory { await client.startEntered }
    let clock = ContinuousClock()
    let began = clock.now

    let first = Task { try? await session.shutdown() }
    let second = Task { try? await session.shutdown() }
    await first.value
    await second.value

    #expect(await client.closeCount == 1)
    #expect(session.lifecycle == .stopped)
    #expect(session.hasActiveTasks == false)
    #expect(began.duration(to: clock.now) < .seconds(2))
}

@MainActor
@Test func shutdownWaitsForStartingGateAndPreventsRestart() async throws {
    let client = GatedSnapshotsClient()
    let session = AccessoryUsageSession(client: client, store: UsageStore())
    let finished = AsyncFlag()
    await session.start()
    try await eventuallyAccessory { await client.snapshotCalls == 1 }

    let shutdown = Task {
        try? await session.shutdown()
        await finished.set()
    }
    try await eventuallyAccessory { await client.closeEntered }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await finished.value == false)

    await client.releaseCloseAndSnapshots()
    await shutdown.value
    #expect(session.lifecycle == .stopped)
    #expect(session.hasActiveTasks == false)
    #expect(await client.closeCount == 1)

    await session.start()
    #expect(await client.snapshotCalls == 1)
    #expect(await client.startCalls == 0)
}

@MainActor
@Test func initialFailureReconnectsAndDisconnectRequiresFreshSnapshot() async throws {
    let first = UsageNormalizer.normalize(.init(primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 1)))
    let second = UsageNormalizer.normalize(.init(primary: .init(usedPercent: 30, windowDurationMins: 300, resetsAt: 2)))
    let client = ReconnectingUsageClient(failInitialStart: true, reconnectSnapshots: [first, second])
    let store = UsageStore()
    let session = AccessoryUsageSession(client: client, store: store, retryDelays: [.milliseconds(1)])
    await session.start()

    try await eventuallyAccessory { client.reconnectCalls == 1 }
    #expect(store.snapshot == first)
    client.disconnect()
    try await eventuallyAccessory { client.reconnectCalls == 2 }
    #expect(store.snapshot == second)
    #expect(client.startCalls == 1)
    try await session.shutdown()
}

@MainActor
@Test func shutdownDuringBackoffCancelsPromptlyAndPreventsFurtherReconnect() async throws {
    let client = ReconnectingUsageClient(failInitialStart: true, reconnectSnapshots: [])
    let session = AccessoryUsageSession(client: client, store: UsageStore(), retryDelays: [.seconds(30)])
    await session.start()
    try await eventuallyAccessory { client.startCalls == 1 }
    let clock = ContinuousClock()
    let began = clock.now
    try await session.shutdown()
    #expect(began.duration(to: clock.now) < .milliseconds(250))
    try await Task.sleep(for: .milliseconds(20))
    #expect(client.reconnectCalls == 0)
    #expect(session.lifecycle == .stopped)
}

@MainActor
@Test func reconnectBackoffProgressesWithoutBusyLoop() async throws {
    let client = ReconnectingUsageClient(failInitialStart: true, reconnectSnapshots: [])
    let session = AccessoryUsageSession(
        client: client,
        store: UsageStore(),
        retryDelays: [.milliseconds(1), .milliseconds(2), .seconds(30)]
    )
    await session.start()
    try await eventuallyAccessory { client.reconnectCalls == 2 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(client.reconnectCalls == 2)
    try await session.shutdown()
}

@MainActor
@Test func cleanupFailureDoesNotReportStoppedAndShutdownCanRetry() async throws {
    let client = ReconnectingUsageClient(failInitialStart: true, reconnectSnapshots: [], closeFailures: 1)
    let store = UsageStore()
    let session = AccessoryUsageSession(client: client, store: store, retryDelays: [.seconds(30)])
    await session.start()
    try await eventuallyAccessory { client.startCalls == 1 }

    await #expect(throws: AppServerClientError.cleanupFailure) { try await session.shutdown() }
    #expect(session.lifecycle == .running)
    #expect(store.snapshot == .unavailable)
    #expect(client.closeCalls == 1)
    try await session.shutdown()
    #expect(session.lifecycle == .stopped)
    #expect(client.closeCalls == 2)
}

@MainActor
private final class OverlayWindowSpy: OverlayWindowControlling {
    var sizes: [NSSize] = []
    var frames: [NSRect] = []
    var animated: [Bool] = []
    var frontCount = 0
    var outCount = 0

    func setContentSize(_ size: NSSize) { sizes.append(size) }
    func applyFrame(_ frame: NSRect, animated: Bool) {
        frames.append(frame)
        self.animated.append(animated)
    }
    func orderFrontRegardless() { frontCount += 1 }
    func orderOut() { outCount += 1 }
}

@MainActor
private final class MutablePointerLocation {
    var value: CGPoint
    init(_ value: CGPoint) { self.value = value }
}

@MainActor
@Test func controllerPlacesIndependentOverlayAndRecalculatesOnHover() {
    let window = OverlayWindowSpy()
    let provider = WindowProviderStub(snapshots: [])
    let screen = CGRect(x: 100, y: 200, width: 1_000, height: 700)
    let controller = OverlayController(
        window: window,
        windowProvider: provider,
        visibleFrames: { [screen] },
        startsMonitoring: false
    )

    controller.recalculatePlacement()
    controller.setHovered(true)

    #expect(window.frames == [
        CGRect(x: 1_000, y: 248, width: 52, height: 52),
        CGRect(x: 961, y: 235, width: 130, height: 78),
    ])
}

@MainActor
@Test func userMoveBecomesStableAnchorAcrossTimerRecalculation() {
    let window = OverlayWindowSpy()
    let store = TestAnchorStore()
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 1_000, height: 700)] },
        startsMonitoring: false,
        anchorStore: store
    )

    controller.recordUserMove(CGRect(x: 220, y: 180, width: 52, height: 52))
    controller.recalculatePlacement()
    controller.recalculatePlacement()

    #expect(store.saved == [CGPoint(x: 246, y: 206)])
    #expect(window.frames.suffix(2).allSatisfy { $0 == CGRect(x: 220, y: 180, width: 52, height: 52) })
}

@MainActor
@Test func hoverRoundTripKeepsOneCenterWithoutDrift() {
    let window = OverlayWindowSpy()
    let store = TestAnchorStore(loaded: CGPoint(x: 500, y: 350))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 1_000, height: 700)] },
        startsMonitoring: false,
        anchorStore: store
    )

    controller.recalculatePlacement()
    controller.setHovered(true)
    controller.setHovered(false)
    controller.setHovered(true)

    #expect(window.frames.map { CGPoint(x: $0.midX, y: $0.midY) }.allSatisfy { $0 == CGPoint(x: 500, y: 350) })
}

@MainActor
@Test func edgeAnchorTemporarilyClampsExpandedFrameWithoutMovingBubbleAnchor() {
    let window = OverlayWindowSpy()
    let store = TestAnchorStore(loaded: CGPoint(x: 780, y: 580))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        startsMonitoring: false,
        anchorStore: store
    )

    controller.setHovered(true)
    controller.setHovered(false)
    controller.setHovered(true)

    #expect(store.saved.isEmpty)
    #expect(window.frames == [
        CGRect(x: 670, y: 522, width: 130, height: 78),
        CGRect(x: 748, y: 548, width: 52, height: 52),
        CGRect(x: 670, y: 522, width: 130, height: 78),
    ])
}

@MainActor
@Test func manualAnchorTracksSecondaryScreenAndClampsAfterScreenRemoval() {
    let window = OverlayWindowSpy()
    let screens = MutableScreens([
        CGRect(x: 0, y: 0, width: 800, height: 600),
        CGRect(x: 800, y: 0, width: 800, height: 600),
    ])
    let store = TestAnchorStore(loaded: CGPoint(x: 1_200, y: 300))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { screens.frames },
        startsMonitoring: false,
        anchorStore: store
    )

    controller.recalculatePlacement()
    #expect(window.frames.last?.midX == 1_200)
    screens.frames = [CGRect(x: 0, y: 0, width: 800, height: 600)]
    controller.recalculatePlacement()

    #expect(window.frames.last == CGRect(x: 748, y: 274, width: 52, height: 52))
    #expect(store.saved.last == CGPoint(x: 774, y: 300))
}

@MainActor
@Test func restoredManualAnchorOverridesFutureAttachedDecision() {
    let window = OverlayWindowSpy()
    let pet = codexWindow(id: 1, layer: 3, bounds: CGRect(x: 300, y: 250, width: 100, height: 100))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: [pet]),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        identityRule: testIdentityRule,
        trayRisk: .none,
        startsMonitoring: false,
        anchorStore: TestAnchorStore(loaded: CGPoint(x: 150, y: 150))
    )

    controller.recalculatePlacement()

    #expect(window.frames == [CGRect(x: 124, y: 124, width: 52, height: 52)])
}

@MainActor
@Test func automaticIndependentAnchorDoesNotOverrideLaterAttachedDecision() {
    let window = OverlayWindowSpy()
    let provider = MutableWindowProvider()
    let controller = OverlayController(
        window: window,
        windowProvider: provider,
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        identityRule: testIdentityRule,
        trayRisk: .none,
        startsMonitoring: false
    )

    controller.recalculatePlacement()
    provider.snapshots = [codexWindow(id: 1, layer: 3, bounds: CGRect(x: 300, y: 250, width: 100, height: 100))]
    controller.recalculatePlacement()

    #expect(window.frames == [
        CGRect(x: 700, y: 48, width: 52, height: 52),
        CGRect(x: 240, y: 274, width: 52, height: 52),
    ])
}

@Test func userDefaultsAnchorStoreRestoresValidValuesAndRejectsInvalidGeometry() {
    let suite = "OverlayAnchorStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsOverlayAnchorStore(defaults: defaults)

    #expect(store.load() == nil)
    store.save(CGPoint(x: 321.5, y: -42))
    #expect(store.load() == CGPoint(x: 321.5, y: -42))

    defaults.set(Double.nan, forKey: "overlay.collapsedCenter.x")
    #expect(store.load() == nil)
    defaults.set(2_000_000.0, forKey: "overlay.collapsedCenter.x")
    #expect(store.load() == nil)

    let beforeY = defaults.double(forKey: "overlay.collapsedCenter.y")
    store.save(CGPoint(x: CGFloat.infinity, y: 99))
    #expect(defaults.double(forKey: "overlay.collapsedCenter.y") == beforeY)
}

@MainActor
@Test func controllerHidesWhenScreensDisappearAndShowsAfterRecovery() {
    let window = OverlayWindowSpy()
    let screens = MutableScreens([CGRect(x: 0, y: 0, width: 800, height: 600)])
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { screens.frames },
        startsMonitoring: false
    )
    controller.show()
    controller.recalculatePlacement()

    screens.frames = []
    controller.recalculatePlacement()
    screens.frames = [CGRect(x: -1_000, y: 100, width: 800, height: 600)]
    controller.recalculatePlacement()

    #expect(window.outCount == 1)
    #expect(window.frames.last == CGRect(x: -252, y: 100, width: 52, height: 52))
    #expect(window.frontCount == 2)
}

@MainActor
@Test func invalidNewPlacementKeepsOnlyAStillSafeLastFrame() {
    let window = OverlayWindowSpy()
    let screens = MutableScreens([CGRect(x: 0, y: 0, width: 800, height: 600)])
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { screens.frames },
        startsMonitoring: false
    )
    controller.recalculatePlacement()
    let safeFrame = window.frames.last

    screens.frames = [CGRect(x: 0, y: 0, width: 40, height: 40)]
    controller.recalculatePlacement()

    #expect(window.frames.last == safeFrame)
    #expect(window.outCount == 1)
}

@MainActor
@Test func attachedFailureFallsBackToIndependentSafePosition() {
    let window = OverlayWindowSpy()
    let pet = codexWindow(id: 1, layer: 3, bounds: CGRect(x: 300, y: 250, width: 100, height: 100))
    let blockingSurface = codexWindow(id: 2, layer: 8, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: [pet, blockingSurface]),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        identityRule: testIdentityRule,
        trayRisk: .none,
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(window.frames == [CGRect(x: 700, y: 48, width: 52, height: 52)])
}

@MainActor
@Test func petOutsideCurrentScreensFallsBackToIndependentPosition() {
    let window = OverlayWindowSpy()
    let pet = codexWindow(id: 1, layer: 3, bounds: CGRect(x: 2_000, y: 2_000, width: 100, height: 100))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: [pet]),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        identityRule: testIdentityRule,
        trayRisk: .none,
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(window.frames == [CGRect(x: 700, y: 48, width: 52, height: 52)])
}

@MainActor
@Test func compactExpandedOverlayUsesAvailableAttachedPlacement() {
    let window = OverlayWindowSpy()
    let pet = codexWindow(id: 1, layer: 3, bounds: CGRect(x: 220, y: 50, width: 60, height: 60))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: [pet]),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 500, height: 200)] },
        identityRule: testIdentityRule,
        trayRisk: .none,
        startsMonitoring: false
    )

    controller.recalculatePlacement()
    controller.setHovered(true)

    #expect(window.frames.last == CGRect(x: 82, y: 41, width: 130, height: 78))
}

@MainActor
@Test func productionTrayRiskDefaultsToIndependentEvenWithIdentityRule() {
    let window = OverlayWindowSpy()
    let pet = codexWindow(id: 1, layer: 3, bounds: CGRect(x: 300, y: 250, width: 100, height: 100))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: [pet]),
        visibleFrames: { [CGRect(x: 0, y: 0, width: 800, height: 600)] },
        identityRule: testIdentityRule,
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(window.frames == [CGRect(x: 700, y: 48, width: 52, height: 52)])
}

@MainActor
@Test func attachedFailureOnSecondaryScreenFallsBackOnThatScreen() {
    let window = OverlayWindowSpy()
    let pet = codexWindow(id: 1, layer: 3, bounds: CGRect(x: 1_100, y: 250, width: 100, height: 100))
    let blocker = codexWindow(id: 2, layer: 8, bounds: CGRect(x: 800, y: 0, width: 800, height: 600))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: [pet, blocker]),
        visibleFrames: { [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 800, height: 600),
        ] },
        identityRule: testIdentityRule,
        trayRisk: .none,
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(window.frames == [CGRect(x: 1_500, y: 48, width: 52, height: 52)])
}

@MainActor
@Test func independentPlacementSkipsScreensThatCannotContainPanel() {
    let window = OverlayWindowSpy()
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [
            CGRect(x: 0, y: 0, width: 40, height: 40),
            CGRect(x: 800, y: 0, width: 800, height: 600),
        ] },
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(window.frames == [CGRect(x: 1_500, y: 48, width: 52, height: 52)])
}

@MainActor
@Test func noScreenThatContainsPanelHidesOverlay() {
    let window = OverlayWindowSpy()
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [
            CGRect(x: 0, y: 0, width: 40, height: 40),
            CGRect(x: 100, y: 0, width: 50, height: 50),
        ] },
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(window.frames.isEmpty)
    #expect(window.outCount == 1)
}

@MainActor
@Test func attachedTargetScreenThatCannotContainPanelFallsBackToAnotherScreen() {
    let window = OverlayWindowSpy()
    let pet = codexWindow(id: 1, layer: 3, bounds: CGRect(x: 810, y: 5, width: 20, height: 20))
    let controller = OverlayController(
        window: window,
        windowProvider: WindowProviderStub(snapshots: [pet]),
        visibleFrames: { [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 40, height: 40),
        ] },
        identityRule: testIdentityRule,
        trayRisk: .none,
        startsMonitoring: false
    )

    controller.recalculatePlacement()

    #expect(window.frames == [CGRect(x: 700, y: 48, width: 52, height: 52)])
}

@MainActor
@Test func controllerDeinitCancelsInjectedMonitoring() {
    let monitoring = OverlayMonitoringSpy()
    weak var releasedController: OverlayController?
    do {
        let controller = OverlayController(
            window: OverlayWindowSpy(),
            windowProvider: WindowProviderStub(snapshots: []),
            visibleFrames: { [] },
            monitoring: monitoring
        )
        releasedController = controller
    }

    #expect(releasedController == nil)
    #expect(monitoring.cancelCount == 1)
}

@MainActor
@Test func stopMonitoringIsIdempotent() {
    let monitoring = OverlayMonitoringSpy()
    let controller = OverlayController(
        window: OverlayWindowSpy(),
        windowProvider: WindowProviderStub(snapshots: []),
        visibleFrames: { [] },
        monitoring: monitoring
    )

    controller.stopMonitoring()
    controller.stopMonitoring()

    #expect(monitoring.cancelCount == 1)
}

private let testIdentityRule = PetIdentityRule.allowlistedMetadata(.init(
    bundleIdentifier: "com.openai.codex",
    layer: 3,
    sharingState: 1,
    requiresNameField: true
))

private func codexWindow(id: UInt32, layer: Int, bounds: CGRect) -> WindowSnapshot {
    WindowSnapshot(
        windowID: id,
        ownerPID: 42,
        bundleIdentifier: "com.openai.codex",
        layer: layer,
        alpha: 1,
        bounds: bounds,
        sharingState: 1,
        isOnScreen: true,
        nameFieldPresent: true
    )
}

private struct WindowProviderStub: WindowSnapshotProviding {
    let snapshots: [WindowSnapshot]
    func currentSnapshots() -> [WindowSnapshot] { snapshots }
}

@MainActor
private final class MutableWindowProvider: WindowSnapshotProviding {
    var snapshots: [WindowSnapshot] = []
    func currentSnapshots() -> [WindowSnapshot] { snapshots }
}

@MainActor
private final class CountingWindowProvider: WindowSnapshotProviding {
    private(set) var readCount = 0
    func currentSnapshots() -> [WindowSnapshot] {
        readCount += 1
        return []
    }
}

@MainActor
private final class OverlayMonitoringSpy: OverlayMonitoring {
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
}

private final class TestAnchorStore: OverlayAnchorStoring {
    let loaded: CGPoint?
    private(set) var saved: [CGPoint] = []

    init(loaded: CGPoint? = nil) { self.loaded = loaded }
    func load() -> CGPoint? { loaded }
    func save(_ center: CGPoint) { saved.append(center) }
}

@MainActor
private final class MutableScreens {
    var frames: [CGRect]
    init(_ frames: [CGRect]) { self.frames = frames }
}

private actor HangingUsageClient: UsageStreamingClient {
    private var continuation: AsyncStream<UsageSnapshot>.Continuation?
    private(set) var closeCount = 0
    private(set) var startEntered = false

    func snapshots() -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.unavailable)
        }
    }

    func start() async throws -> UsageSnapshot {
        startEntered = true
        while !Task.isCancelled { try await Task.sleep(for: .seconds(30)) }
        throw CancellationError()
    }

    func reconnect() async throws -> UsageSnapshot { try await start() }

    func close() async throws {
        closeCount += 1
        continuation?.finish()
    }
}

private final class ReconnectingUsageClient: UsageStreamingClient, @unchecked Sendable {
    private let lock = NSLock()
    private let failInitialStart: Bool
    private var reconnectSnapshots: [UsageSnapshot]
    private var continuation: AsyncStream<UsageSnapshot>.Continuation?
    private var _startCalls = 0
    private var _reconnectCalls = 0
    private var _closeCount = 0
    private var closeFailures: Int
    var startCalls: Int { lock.withLock { _startCalls } }
    var reconnectCalls: Int { lock.withLock { _reconnectCalls } }
    var closeCalls: Int { lock.withLock { _closeCount } }

    init(failInitialStart: Bool, reconnectSnapshots: [UsageSnapshot], closeFailures: Int = 0) {
        self.failInitialStart = failInitialStart
        self.reconnectSnapshots = reconnectSnapshots
        self.closeFailures = closeFailures
    }

    func snapshots() -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(.unavailable)
        }
    }

    func start() async throws -> UsageSnapshot {
        lock.withLock { _startCalls += 1 }
        if failInitialStart { throw AppServerClientError.transportFailure }
        return reconnectSnapshots.first ?? .unavailable
    }

    func reconnect() async throws -> UsageSnapshot {
        try lock.withLock {
            _reconnectCalls += 1
            guard !reconnectSnapshots.isEmpty else { throw AppServerClientError.transportFailure }
            return reconnectSnapshots.removeFirst()
        }
    }

    func disconnect() { lock.withLock { continuation }?.yield(.unavailable) }
    func close() async throws {
        let result: (AsyncStream<UsageSnapshot>.Continuation?, Bool) = lock.withLock {
            _closeCount += 1
            if closeFailures > 0 { closeFailures -= 1; return (continuation, true) }
            return (continuation, false)
        }
        if result.1 { throw AppServerClientError.cleanupFailure }
        result.0?.finish()
    }
}

private actor GatedSnapshotsClient: UsageStreamingClient {
    private var snapshotsGate: CheckedContinuation<Void, Never>?
    private var closeGate: CheckedContinuation<Void, Never>?
    private(set) var snapshotCalls = 0
    private(set) var startCalls = 0
    private(set) var closeCount = 0
    private(set) var closeEntered = false

    func snapshots() async -> AsyncStream<UsageSnapshot> {
        snapshotCalls += 1
        await withCheckedContinuation { snapshotsGate = $0 }
        return AsyncStream { $0.finish() }
    }

    func start() async throws -> UsageSnapshot {
        startCalls += 1
        return .unavailable
    }

    func reconnect() async throws -> UsageSnapshot { try await start() }

    func close() async throws {
        closeCount += 1
        closeEntered = true
        await withCheckedContinuation { closeGate = $0 }
    }

    func releaseCloseAndSnapshots() {
        snapshotsGate?.resume()
        snapshotsGate = nil
        closeGate?.resume()
        closeGate = nil
    }
}

private actor AsyncFlag {
    private(set) var value = false
    func set() { value = true }
}

private func eventuallyAccessory(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition did not become true")
}
