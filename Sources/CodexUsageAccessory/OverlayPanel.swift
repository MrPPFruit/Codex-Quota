import AppKit

public struct OverlayWindowPolicy: Sendable, Equatable {
    public let styleMask: NSWindow.StyleMask
    public let level: NSWindow.Level
    public let canBecomeKey: Bool
    public let canBecomeMain: Bool
    public let hidesOnDeactivate: Bool
    public let isMovable: Bool
    public let isMovableByWindowBackground: Bool

    public static let standard = Self(
        styleMask: [.borderless, .nonactivatingPanel],
        level: .floating,
        canBecomeKey: false,
        canBecomeMain: false,
        hidesOnDeactivate: false,
        isMovable: true,
        isMovableByWindowBackground: true
    )
}

public struct OverlayPanelMoveClassifier: Sendable {
    private var expectedProgrammaticFrame: NSRect?
    private var nextAnimationGeneration: UInt = 0
    private var activeAnimationGeneration: UInt?
    private var activeAnimationTarget: NSRect?

    public init() {}

    public mutating func recordProgrammaticFrame(_ frame: NSRect) {
        nextAnimationGeneration &+= 1
        activeAnimationGeneration = nil
        activeAnimationTarget = nil
        expectedProgrammaticFrame = frame
    }

    public mutating func beginProgrammaticAnimation(to frame: NSRect) -> UInt {
        nextAnimationGeneration &+= 1
        activeAnimationGeneration = nextAnimationGeneration
        activeAnimationTarget = frame
        expectedProgrammaticFrame = nil
        return nextAnimationGeneration
    }

    public mutating func finishProgrammaticAnimation(_ generation: UInt) {
        guard activeAnimationGeneration == generation else { return }
        expectedProgrammaticFrame = activeAnimationTarget
        activeAnimationGeneration = nil
        activeAnimationTarget = nil
    }

    public mutating func interruptProgrammaticAnimation(at frame: NSRect) {
        nextAnimationGeneration &+= 1
        activeAnimationGeneration = nil
        activeAnimationTarget = nil
        expectedProgrammaticFrame = frame
    }

    public mutating func isUserMove(_ frame: NSRect) -> Bool {
        if activeAnimationGeneration != nil { return false }
        defer { expectedProgrammaticFrame = nil }
        guard let expected = expectedProgrammaticFrame else { return true }
        return !Self.approximatelyEqual(frame, expected)
    }

    private static func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 &&
            abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}

@MainActor
public final class OverlayPanel: NSPanel, NSWindowDelegate {
    public var onUserMove: ((NSRect) -> Void)?
    public var contextMenuProvider: (() -> NSMenu?)?
    private var moveClassifier = OverlayPanelMoveClassifier()
    private var animatedTargetFrame: NSRect?

    public init(policy: OverlayWindowPolicy = .standard) {
        super.init(
            contentRect: NSRect(origin: .zero, size: OverlayLayout.collapsedSize),
            styleMask: policy.styleMask,
            backing: .buffered,
            defer: false
        )
        level = policy.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = policy.hidesOnDeactivate
        isMovable = policy.isMovable
        isMovableByWindowBackground = policy.isMovableByWindowBackground
        collectionBehavior = [.transient]
        delegate = self
    }

    public func applyProgrammaticFrame(_ frame: NSRect, animated: Bool) {
        if animated {
            guard animatedTargetFrame != frame else { return }
            let generation = moveClassifier.beginProgrammaticAnimation(to: frame)
            animatedTargetFrame = frame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.moveClassifier.finishProgrammaticAnimation(generation)
                    if self.animatedTargetFrame == frame {
                        self.animatedTargetFrame = nil
                    }
                }
            }
        } else {
            guard animatedTargetFrame != frame else { return }
            animatedTargetFrame = nil
            moveClassifier.recordProgrammaticFrame(frame)
            setFrame(frame, display: false)
        }
    }

    public func windowDidMove(_ notification: Notification) {
        guard moveClassifier.isUserMove(frame) else { return }
        onUserMove?(frame)
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, animatedTargetFrame != nil {
            let interruptedFrame = frame
            animatedTargetFrame = nil
            moveClassifier.interruptProgrammaticAnimation(at: interruptedFrame)
            setFrame(interruptedFrame, display: true)
        }
        super.sendEvent(event)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

}
