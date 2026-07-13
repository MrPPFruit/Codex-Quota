import Foundation

public enum UsageWindowKind: Sendable, Equatable {
    case fiveHour
    case weekly
}

public enum Freshness: Sendable, Equatable {
    case fresh
    case stale
    case unavailable
}

public struct UsageWindow: Sendable, Equatable {
    public let kind: UsageWindowKind
    public let remainingPercent: Double?
    public let resetsAt: Int64?
    public let freshness: Freshness

    public init(
        kind: UsageWindowKind,
        remainingPercent: Double?,
        resetsAt: Int64?,
        freshness: Freshness
    ) {
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.freshness = freshness
    }

    fileprivate static func unavailable(_ kind: UsageWindowKind) -> Self {
        .init(kind: kind, remainingPercent: nil, resetsAt: nil, freshness: .unavailable)
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public let fiveHour: UsageWindow
    public let weekly: UsageWindow

    public init(fiveHour: UsageWindow, weekly: UsageWindow) {
        self.fiveHour = fiveHour
        self.weekly = weekly
    }

    public static let unavailable = Self(
        fiveHour: .unavailable(.fiveHour),
        weekly: .unavailable(.weekly)
    )
}

public struct RateLimitPayload: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public let usedPercent: Double?
        public let windowDurationMins: Int?
        public let resetsAt: Int64?

        public init(usedPercent: Double? = nil, windowDurationMins: Int? = nil, resetsAt: Int64? = nil) {
            self.usedPercent = usedPercent
            self.windowDurationMins = windowDurationMins
            self.resetsAt = resetsAt
        }
    }

    public let primary: Window?
    public let secondary: Window?
    public let additional: [Window]

    public init(primary: Window? = nil, secondary: Window? = nil, additional: [Window] = []) {
        self.primary = primary
        self.secondary = secondary
        self.additional = additional
    }
}

public enum FieldPatch<Value: Sendable & Equatable>: Sendable, Equatable {
    case missing
    case null
    case value(Value)
}

public struct RateLimitPatch: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public let usedPercent: FieldPatch<Double>
        public let windowDurationMins: FieldPatch<Int>
        public let resetsAt: FieldPatch<Int64>

        public init(
            usedPercent: FieldPatch<Double> = .missing,
            windowDurationMins: FieldPatch<Int> = .missing,
            resetsAt: FieldPatch<Int64> = .missing
        ) {
            self.usedPercent = usedPercent
            self.windowDurationMins = windowDurationMins
            self.resetsAt = resetsAt
        }
    }

    public let primary: FieldPatch<Window>
    public let secondary: FieldPatch<Window>

    public init(primary: FieldPatch<Window> = .missing, secondary: FieldPatch<Window> = .missing) {
        self.primary = primary
        self.secondary = secondary
    }
}

public enum FullRefreshReason: Error, Sendable, Equatable {
    case unknownWindowIdentity
    case windowIdentityChanged
}

public enum UsageMergeResult: Sendable, Equatable {
    case merged(RateLimitPayload)
    case requiresFullRefresh(FullRefreshReason)
}

public enum UsageNormalizer {
    public static func normalize(_ payload: RateLimitPayload) -> UsageSnapshot {
        var fiveHour = UsageWindow.unavailable(.fiveHour)
        var weekly = UsageWindow.unavailable(.weekly)

        for window in [payload.primary, payload.secondary].compactMap({ $0 }) + payload.additional {
            guard let usedPercent = window.usedPercent else { continue }
            let normalized: UsageWindow

            switch window.windowDurationMins {
            case 300:
                normalized = makeWindow(kind: .fiveHour, usedPercent: usedPercent, resetsAt: window.resetsAt)
                fiveHour = normalized
            case 10_080:
                normalized = makeWindow(kind: .weekly, usedPercent: usedPercent, resetsAt: window.resetsAt)
                weekly = normalized
            default:
                continue
            }
        }

        return .init(fiveHour: fiveHour, weekly: weekly)
    }

    public static func merge(_ current: RateLimitPayload, _ update: RateLimitPatch) -> UsageMergeResult {
        let primary: RateLimitPayload.Window?
        let secondary: RateLimitPayload.Window?

        switch mergeWindow(current.primary, update.primary) {
        case let .success(window): primary = window
        case let .failure(reason): return .requiresFullRefresh(reason)
        }
        switch mergeWindow(current.secondary, update.secondary) {
        case let .success(window): secondary = window
        case let .failure(reason): return .requiresFullRefresh(reason)
        }

        return .merged(.init(primary: primary, secondary: secondary, additional: current.additional))
    }

    public static func needsRefresh(_ snapshot: UsageSnapshot, now: Int64) -> Bool {
        [snapshot.fiveHour, snapshot.weekly].contains { window in
            window.freshness != .fresh || window.resetsAt.map { $0 <= now } ?? true
        }
    }

    private static func makeWindow(kind: UsageWindowKind, usedPercent: Double, resetsAt: Int64?) -> UsageWindow {
        let remainingPercent = min(100, max(0, 100 - usedPercent))
        return .init(kind: kind, remainingPercent: remainingPercent, resetsAt: resetsAt, freshness: .fresh)
    }

    private static func mergeWindow(
        _ current: RateLimitPayload.Window?,
        _ patch: FieldPatch<RateLimitPatch.Window>
    ) -> Result<RateLimitPayload.Window?, FullRefreshReason> {
        switch patch {
        case .missing:
            return .success(current)
        case .null:
            return .success(nil)
        case let .value(patch):
            let duration: Int
            switch patch.windowDurationMins {
            case .missing:
                guard let knownDuration = current?.windowDurationMins, isKnownDuration(knownDuration) else {
                    return .failure(.unknownWindowIdentity)
                }
                duration = knownDuration
            case .null:
                return .failure(.unknownWindowIdentity)
            case let .value(updatedDuration):
                if current != nil, current?.windowDurationMins == nil {
                    return .failure(.unknownWindowIdentity)
                }
                guard isKnownDuration(updatedDuration) else {
                    return .failure(.unknownWindowIdentity)
                }
                if let currentDuration = current?.windowDurationMins, currentDuration != updatedDuration {
                    return .failure(.windowIdentityChanged)
                }
                duration = updatedDuration
            }

            return .success(.init(
                usedPercent: apply(patch.usedPercent, to: current?.usedPercent),
                windowDurationMins: duration,
                resetsAt: apply(patch.resetsAt, to: current?.resetsAt)
            ))
        }
    }

    private static func apply<Value>(_ patch: FieldPatch<Value>, to current: Value?) -> Value? {
        switch patch {
        case .missing: current
        case .null: nil
        case let .value(value): value
        }
    }

    private static func isKnownDuration(_ duration: Int) -> Bool {
        duration == 300 || duration == 10_080
    }
}

public enum ResetTimeFormatter {
    public static func format(
        _ resetsAt: Int64?,
        includesWeekday: Bool = false,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetsAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if includesWeekday {
            formatter.setLocalizedDateFormatFromTemplate("MMMdEEEjmm")
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        }
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(resetsAt)))
    }
}
