import SwiftUI
import CodexUsageCore

public enum UsageSemanticLevel: Sendable, Equatable {
    case unavailable
    case sufficient
    case attention
    case urgent

    public var color: Color {
        switch self {
        case .sufficient: .green
        case .attention: .orange
        case .urgent: .red
        case .unavailable: .secondary
        }
    }
}

public struct UsageSemanticStyle: Sendable, Equatable {
    public let fiveHour: UsageSemanticLevel
    public let weekly: UsageSemanticLevel

    public init(fiveHourPercent: Double?, weeklyPercent: Double?) {
        fiveHour = Self.level(for: fiveHourPercent)
        weekly = Self.level(for: weeklyPercent)
    }

    public static func level(for percent: Double?) -> UsageSemanticLevel {
        guard let percent else { return .unavailable }
        if percent < 20 { return .urgent }
        if percent < 60 { return .attention }
        return .sufficient
    }
}

public struct UsageAccessibilityDescriptor: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(window: UsageWindow) {
        label = window.kind == .fiveHour ? "5小时额度" : "本周额度"
        guard let percent = window.remainingPercent else {
            value = "不可用"
            return
        }
        let meaning: String = switch UsageSemanticStyle.level(for: percent) {
        case .sufficient: "充足"
        case .attention: "注意"
        case .urgent: "紧张"
        case .unavailable: "不可用"
        }
        value = "剩余\(Int(percent.rounded()))%，\(meaning)"
    }
}
