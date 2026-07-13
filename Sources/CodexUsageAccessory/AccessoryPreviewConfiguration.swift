import AppKit
import CodexUsageCore
import CodexUsageUI

public enum AccessoryPreviewState: String, Sendable, Equatable {
    case sufficient
    case nearFull
    case full
    case attention
    case urgent
    case weeklyFallback
    case unavailable

    public var snapshot: UsageSnapshot {
        guard self != .unavailable else { return .unavailable }
        if self == .weeklyFallback {
            return UsageSnapshot(
                fiveHour: .init(kind: .fiveHour, remainingPercent: nil, resetsAt: nil, freshness: .unavailable),
                weekly: .init(kind: .weekly, remainingPercent: 66, resetsAt: 1_893_715_200, freshness: .fresh)
            )
        }
        let fiveHourPercent: Double = switch self {
        case .sufficient: 80
        case .nearFull: 93
        case .full: 100
        case .attention: 42
        case .urgent: 16
        case .weeklyFallback: 0
        case .unavailable: 0
        }
        return UsageSnapshot(
            fiveHour: UsageWindow(
                kind: .fiveHour,
                remainingPercent: fiveHourPercent,
                resetsAt: 1_893_456_000,
                freshness: .fresh
            ),
            weekly: UsageWindow(
                kind: .weekly,
                remainingPercent: [.nearFull, .full].contains(self) ? 66 : min(100, fiveHourPercent + 2),
                resetsAt: 1_893_715_200,
                freshness: .fresh
            )
        )
    }
}

public enum AccessoryPreviewAppearance: String, Sendable, Equatable {
    case light
    case dark

    fileprivate var name: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

}

/// An opt-in, local-only visual validation surface. It is deliberately sourced
/// only from the launch environment and does not expose IPC or network control.
public struct AccessoryPreviewConfiguration: Sendable, Equatable {
    public static let modeVariable = "CODEX_ACCESSORY_PREVIEW_MODE"
    public static let stateVariable = "CODEX_ACCESSORY_PREVIEW_STATE"
    public static let appearanceVariable = "CODEX_ACCESSORY_PREVIEW_APPEARANCE"
    public static let reduceMotionVariable = "CODEX_ACCESSORY_PREVIEW_REDUCE_MOTION"
    public static let reduceTransparencyVariable = "CODEX_ACCESSORY_PREVIEW_REDUCE_TRANSPARENCY"
    public static let expandedVariable = "CODEX_ACCESSORY_PREVIEW_EXPANDED"
    public static let autoExitVariable = "CODEX_ACCESSORY_PREVIEW_AUTO_EXIT_SECONDS"

    public let state: AccessoryPreviewState
    public let appearance: AccessoryPreviewAppearance?
    public let reduceMotionOverride: Bool?
    public let reduceTransparencyOverride: Bool?
    public let expanded: Bool
    public let autoExitSeconds: Int?

    public var snapshot: UsageSnapshot { state.snapshot }

    public static func parse(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard environment[modeVariable] == "1" else { return nil }
        let state = environment[stateVariable]
            .flatMap(AccessoryPreviewState.init(rawValue:)) ?? .unavailable
        let appearance = environment[appearanceVariable]
            .flatMap(AccessoryPreviewAppearance.init(rawValue:))
        let autoExitSeconds = environment[autoExitVariable]
            .flatMap(Int.init)
            .flatMap { (1...30).contains($0) ? $0 : nil }
        return Self(
            state: state,
            appearance: appearance,
            reduceMotionOverride: environment[reduceMotionVariable] == "1" ? true : nil,
            reduceTransparencyOverride: environment[reduceTransparencyVariable] == "1" ? true : nil,
            expanded: environment[expandedVariable] == "1",
            autoExitSeconds: autoExitSeconds
        )
    }

    @MainActor
    public func applyAppearance(panel: NSPanel) {
        guard let appearance, let value = NSAppearance(named: appearance.name) else { return }
        panel.appearance = value
    }
}
