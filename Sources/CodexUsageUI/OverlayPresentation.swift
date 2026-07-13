import CodexUsageCore
import Foundation
import SwiftUI

@MainActor
public final class OverlayExpansionStore: ObservableObject {
    @Published public private(set) var isExpanded: Bool

    public init(isExpanded: Bool = false) {
        self.isExpanded = isExpanded
    }

    public func setExpanded(_ isExpanded: Bool) {
        guard self.isExpanded != isExpanded else { return }
        self.isExpanded = isExpanded
    }
}

public struct CollapsedUsagePresentation: Sendable, Equatable {
    public let window: UsageWindow
    public let compactLabel: String
    public let semanticLevel: UsageSemanticLevel
    public let accessibilityLabel: String
    public let accessibilityValue: String

    public static func select(from snapshot: UsageSnapshot) -> Self {
        if snapshot.fiveHour.isDisplayable {
            return presentation(window: snapshot.fiveHour, compactLabel: "5h")
        }
        if snapshot.weekly.isDisplayable {
            return presentation(window: snapshot.weekly, compactLabel: "本周")
        }
        return Self(
            window: snapshot.fiveHour,
            compactLabel: "额度",
            semanticLevel: .unavailable,
            accessibilityLabel: "额度",
            accessibilityValue: "不可用"
        )
    }

    private static func presentation(window: UsageWindow, compactLabel: String) -> Self {
        let accessibility = UsageAccessibilityDescriptor(window: window)
        return Self(
            window: window,
            compactLabel: compactLabel,
            semanticLevel: UsageSemanticStyle.level(for: window.remainingPercent),
            accessibilityLabel: accessibility.label,
            accessibilityValue: accessibility.value
        )
    }
}

public enum UsageVisibleQuotaText {
    public static func make(for window: UsageWindow) -> String {
        guard let value = window.remainingPercent else { return "--" }
        return "\(Int(value.rounded()))"
    }
}

private extension UsageWindow {
    var isDisplayable: Bool {
        remainingPercent != nil && freshness != .unavailable
    }
}

public struct CompactResetPresentation: Sendable, Equatable {
    public let date: String
    public let time: String

    public init(date: String, time: String) {
        self.date = date
        self.time = time
    }

    public static func make(
        for window: UsageWindow,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> Self {
        guard window.freshness != .unavailable, let resetsAt = window.resetsAt else {
            return Self(date: "重置", time: "不可用")
        }
        let value = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.setLocalizedDateFormatFromTemplate(window.kind == .weekly ? "MdEEE" : "Md")
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.setLocalizedDateFormatFromTemplate("jmm")
        return Self(
            date: dateFormatter.string(from: value),
            time: timeFormatter.string(from: value)
        )
    }
}
