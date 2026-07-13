import AppKit
import CodexUsageCore
import CodexUsageUI
import SwiftUI

public enum OverlayLayout {
    public static let collapsedSize = NSSize(width: 52, height: 52)
    public static let expandedSize = NSSize(width: 130, height: 78)
    public static let expandedCornerRadius: CGFloat = 22
}

public struct OverlayHitRegion: Sendable, Equatable {
    public let size: NSSize
    public let cornerRadius: CGFloat

    public init(size: NSSize, cornerRadius: CGFloat) {
        self.size = size
        self.cornerRadius = min(cornerRadius, min(size.width, size.height) / 2)
    }

    public func contains(_ point: NSPoint) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return false }
        let radius = cornerRadius
        if point.x >= radius, point.x <= size.width - radius { return true }
        if point.y >= radius, point.y <= size.height - radius { return true }
        let centerX = point.x < radius ? radius : size.width - radius
        let centerY = point.y < radius ? radius : size.height - radius
        return pow(point.x - centerX, 2) + pow(point.y - centerY, 2) <= pow(radius, 2)
    }
}

public enum OverlayHoverPolicy {
    public static let exitMargin: CGFloat = 10

    public static func retentionRegion(
        entryFrame: CGRect?,
        expandedFrame: CGRect,
        margin: CGFloat = exitMargin
    ) -> CGRect {
        let base = entryFrame?.union(expandedFrame) ?? expandedFrame
        return base.insetBy(dx: -margin, dy: -margin)
    }
}

@MainActor
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var contextMenuProvider: (() -> NSMenu?)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let radius = bounds.size == OverlayLayout.collapsedSize
            ? bounds.width / 2
            : OverlayLayout.expandedCornerRadius
        guard OverlayHitRegion(size: bounds.size, cornerRadius: radius).contains(point) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
public protocol OverlayWindowControlling: AnyObject {
    func applyFrame(_ frame: NSRect, animated: Bool)
    func orderFrontRegardless()
    func orderOut()
}

extension OverlayPanel: OverlayWindowControlling {
    public func applyFrame(_ frame: NSRect, animated: Bool) {
        applyProgrammaticFrame(frame, animated: animated)
    }
    public func orderOut() { orderOut(nil) }
}

@MainActor
public protocol OverlayMonitoring: AnyObject {
    func cancel()
}

@MainActor
private final class SystemOverlayMonitor: OverlayMonitoring {
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?

    init(action: @escaping @MainActor () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in action() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

@MainActor
public final class OverlayController {
    private let window: any OverlayWindowControlling
    private let windowProvider: any WindowSnapshotProviding
    private let visibleFrames: @MainActor () -> [CGRect]
    private let identityRule: PetIdentityRule
    private let trayRisk: TrayRisk
    private let forcedExpanded: Bool?
    private let anchorStore: any OverlayAnchorStoring
    private let expansionStore: OverlayExpansionStore
    private let pointerLocation: @MainActor () -> CGPoint
    private let hoverPollInterval: Duration
    private let monitoringFactory: @MainActor (@escaping @MainActor () -> Void) -> any OverlayMonitoring
    private var panelSize: NSSize
    private var manualAnchor: CGPoint?
    private var automaticAnchor: CGPoint?
    private var lastSafeFrame: CGRect?
    private var hoverEntryFrame: CGRect?
    private var hoverExitTask: Task<Void, Never>?
    private var monitoring: (any OverlayMonitoring)?
    private var temporarilyHidden = false
    private var lifecycleAvailable = true
    private(set) var isVisible = false

    public init(
        window: any OverlayWindowControlling,
        windowProvider: any WindowSnapshotProviding = SystemWindowProvider(),
        visibleFrames: @escaping @MainActor () -> [CGRect] = OverlayController.systemVisibleFrames,
        identityRule: PetIdentityRule = .disabled,
        trayRisk: TrayRisk = .possibleWithoutBounds,
        monitoring: (any OverlayMonitoring)? = nil,
        monitoringFactory: (@MainActor (@escaping @MainActor () -> Void) -> any OverlayMonitoring)? = nil,
        startsMonitoring: Bool = true,
        forcedExpanded: Bool? = nil,
        anchorStore: any OverlayAnchorStoring = TransientOverlayAnchorStore(),
        expansionStore: OverlayExpansionStore = OverlayExpansionStore(),
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        hoverPollInterval: Duration = .milliseconds(60)
    ) {
        self.window = window
        self.windowProvider = windowProvider
        self.visibleFrames = visibleFrames
        self.identityRule = identityRule
        self.trayRisk = trayRisk
        self.forcedExpanded = forcedExpanded
        self.anchorStore = anchorStore
        self.expansionStore = expansionStore
        self.pointerLocation = pointerLocation
        self.hoverPollInterval = hoverPollInterval
        self.monitoringFactory = monitoringFactory ?? { action in SystemOverlayMonitor(action: action) }
        self.panelSize = forcedExpanded == true ? OverlayLayout.expandedSize : OverlayLayout.collapsedSize
        self.manualAnchor = anchorStore.load()
        self.monitoring = nil
        expansionStore.setExpanded(forcedExpanded == true)
        if startsMonitoring {
            self.monitoring = monitoring ?? self.makeMonitoring()
        }
    }

    public convenience init(
        panel: OverlayPanel,
        store: UsageStore,
        reduceMotionOverride: Bool? = nil,
        reduceTransparencyOverride: Bool? = nil,
        forcedExpanded: Bool? = nil,
        startsMonitoring: Bool = true
    ) {
        let expansionStore = OverlayExpansionStore(isExpanded: forcedExpanded == true)
        self.init(
            window: panel,
            startsMonitoring: startsMonitoring,
            forcedExpanded: forcedExpanded,
            anchorStore: UserDefaultsOverlayAnchorStore(),
            expansionStore: expansionStore
        )
        panel.onUserMove = { [weak self] frame in self?.recordUserMove(frame) }
        let hostingView = OverlayHostingView(rootView: UsageOverlayView(
            store: store,
            expansionStore: expansionStore,
            reduceMotionOverride: reduceMotionOverride,
            reduceTransparencyOverride: reduceTransparencyOverride,
            forcedExpanded: forcedExpanded
        ) { [weak self] hovered, animated in
            self?.updateHover(hovered, animated: animated)
        })
        hostingView.contextMenuProvider = { [weak panel] in panel?.contextMenuProvider?() }
        panel.contentView = hostingView
    }

    public func setHovered(_ hovered: Bool, animated: Bool = true) {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        if hovered, !expansionStore.isExpanded {
            hoverEntryFrame = lastSafeFrame
        }
        applyExpanded(hovered, animated: animated)
    }

    func updateHover(_ hovered: Bool, animated: Bool = true) {
        guard forcedExpanded == nil else { return }
        hoverExitTask?.cancel()
        hoverExitTask = nil
        if hovered {
            if !expansionStore.isExpanded { hoverEntryFrame = lastSafeFrame }
            applyExpanded(true, animated: animated)
            return
        }
        guard expansionStore.isExpanded else { return }

        hoverExitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: hoverPollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let expandedFrame = lastSafeFrame else {
                    applyExpanded(false, animated: animated)
                    return
                }
                let retention = OverlayHoverPolicy.retentionRegion(
                    entryFrame: hoverEntryFrame,
                    expandedFrame: expandedFrame
                )
                guard retention.contains(pointerLocation()) else {
                    applyExpanded(false, animated: animated)
                    return
                }
            }
        }
    }

    private func applyExpanded(_ hovered: Bool, animated: Bool) {
        let expanded = forcedExpanded ?? hovered
        expansionStore.setExpanded(expanded)
        panelSize = expanded ? OverlayLayout.expandedSize : OverlayLayout.collapsedSize
        recalculatePlacement(animated: animated)
        if !expanded { hoverEntryFrame = nil }
    }

    public func show() {
        isVisible = true
        if lifecycleAvailable { startMonitoring() }
        recalculatePlacement()
        if lifecycleAvailable, !temporarilyHidden { window.orderFrontRegardless() }
    }

    public func hide() {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        isVisible = false
        stopMonitoring()
        if forcedExpanded == nil { applyExpanded(false, animated: false) }
        window.orderOut()
    }

    public func toggleVisibility() {
        isVisible ? hide() : show()
    }

    public func recalculatePlacement(animated: Bool = false) {
        guard lifecycleAvailable else { return }
        let screens = visibleFrames().filter { !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 }
        guard !screens.isEmpty else {
            hideTemporarily()
            return
        }

        let decision: PetAffinityDecision
        if identityRule == .disabled {
            decision = .independent(.identityRuleUnavailable)
        } else if trayRisk == .possibleWithoutBounds {
            decision = .independent(.unboundedTrayRisk)
        } else {
            decision = PetAffinityDecision.decide(
                snapshots: windowProvider.currentSnapshots(),
                identityRule: identityRule,
                trayRisk: trayRisk
            )
        }
        var placement: OverlayPlacementResult
        if let anchor = manualAnchor {
            placement = anchoredPlacement(anchor: anchor, screens: screens, persistsClamp: true)
        } else { switch decision {
        case let .attached(pet, exclusions):
            if let targetScreen = screens.first(where: { $0.contains(CGPoint(x: pet.midX, y: pet.midY)) }) {
                placement = OverlayPlacement.attached(
                    panelSize: panelSize,
                    visibleFrame: targetScreen,
                    petFrame: pet,
                    exclusions: exclusions
                )
                if case .failure = placement {
                    placement = independentPlacement(preferredScreen: targetScreen, screens: screens)
                }
            } else {
                placement = independentPlacement(preferredScreen: nil, screens: screens)
            }
        case .independent:
            if let anchor = automaticAnchor {
                placement = anchoredPlacement(anchor: anchor, screens: screens, persistsClamp: false)
            } else {
                placement = independentPlacement(preferredScreen: nil, screens: screens)
            }
        } }

        switch placement {
        case let .placed(frame, _):
            window.applyFrame(frame, animated: animated)
            lastSafeFrame = frame
            if manualAnchor == nil, automaticAnchor == nil, case .independent = decision {
                automaticAnchor = CGPoint(x: frame.midX, y: frame.midY)
            }
            if temporarilyHidden, isVisible { window.orderFrontRegardless() }
            temporarilyHidden = false
        case .failure:
            let oldFrameIsStillSafe = lastSafeFrame.map { old in
                old.size == panelSize && screens.contains(where: { $0.contains(old) })
            } ?? false
            if !oldFrameIsStillSafe { hideTemporarily() }
        }
    }

    public func stopMonitoring() {
        let monitoring = monitoring
        self.monitoring = nil
        monitoring?.cancel()
    }

    public func startMonitoring() {
        guard monitoring == nil else { return }
        monitoring = makeMonitoring()
    }

    public func setLifecycleAvailable(_ isAvailable: Bool) {
        guard lifecycleAvailable != isAvailable else { return }
        lifecycleAvailable = isAvailable
        if isAvailable {
            if isVisible {
                startMonitoring()
                recalculatePlacement()
                if !temporarilyHidden { window.orderFrontRegardless() }
            }
        } else {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            if forcedExpanded == nil { applyExpanded(false, animated: false) }
            stopMonitoring()
            window.orderOut()
        }
    }

    public func recordUserMove(_ frame: CGRect) {
        guard frame.isUsableFrame else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard center.x.isFinite, center.y.isFinite else { return }
        lastSafeFrame = frame
        if forcedExpanded == nil, expansionStore.isExpanded {
            hoverEntryFrame = frame
        }
        manualAnchor = center
        anchorStore.save(center)
    }

    private func hideTemporarily() {
        guard !temporarilyHidden else { return }
        window.orderOut()
        temporarilyHidden = true
    }

    private func makeMonitoring() -> any OverlayMonitoring {
        monitoringFactory { [weak self] in self?.recalculatePlacement() }
    }

    public static func systemVisibleFrames() -> [CGRect] {
        let main = NSScreen.main
        return ([main].compactMap { $0 } + NSScreen.screens.filter { $0 !== main }).map(\.visibleFrame)
    }

    private func independentPlacement(preferredScreen: CGRect?, screens: [CGRect], size: CGSize? = nil) -> OverlayPlacementResult {
        let orderedScreens = [preferredScreen].compactMap { $0 } + screens.filter { $0 != preferredScreen }
        for screen in orderedScreens {
            let result = OverlayPlacement.independent(panelSize: size ?? panelSize, visibleFrame: screen)
            if case .placed = result { return result }
        }
        return .failure(.panelDoesNotFit)
    }

    private func anchoredPlacement(
        anchor: CGPoint,
        screens: [CGRect],
        persistsClamp: Bool
    ) -> OverlayPlacementResult {
        let containingScreen = screens.first(where: { $0.contains(anchor) })
        let screen = containingScreen ?? screens.min {
            $0.distanceSquared(to: anchor) < $1.distanceSquared(to: anchor)
        }
        guard let screen, panelSize.width <= screen.width, panelSize.height <= screen.height else {
            return .failure(.panelDoesNotFit)
        }

        var logicalAnchor = anchor
        if containingScreen == nil {
            logicalAnchor = CGPoint(
                x: min(max(anchor.x, screen.minX + OverlayLayout.collapsedSize.width / 2), screen.maxX - OverlayLayout.collapsedSize.width / 2),
                y: min(max(anchor.y, screen.minY + OverlayLayout.collapsedSize.height / 2), screen.maxY - OverlayLayout.collapsedSize.height / 2)
            )
            if persistsClamp {
                manualAnchor = logicalAnchor
                anchorStore.save(logicalAnchor)
            } else {
                automaticAnchor = logicalAnchor
            }
        }

        let origin = CGPoint(
            x: min(max(logicalAnchor.x - panelSize.width / 2, screen.minX), screen.maxX - panelSize.width),
            y: min(max(logicalAnchor.y - panelSize.height / 2, screen.minY), screen.maxY - panelSize.height)
        )
        return .placed(CGRect(
            x: origin.x,
            y: origin.y,
            width: panelSize.width,
            height: panelSize.height
        ), direction: .independent)
    }

    isolated deinit {
        monitoring?.cancel()
        hoverExitTask?.cancel()
    }
}

private extension CGRect {
    var isUsableFrame: Bool {
        !isNull && !isInfinite && width > 0 && height > 0 &&
            [minX, minY, width, height].allSatisfy(\.isFinite)
    }

    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = point.x < minX ? minX - point.x : (point.x > maxX ? point.x - maxX : 0)
        let dy = point.y < minY ? minY - point.y : (point.y > maxY ? point.y - maxY : 0)
        return dx * dx + dy * dy
    }
}
