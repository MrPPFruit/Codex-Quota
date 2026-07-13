import Foundation
import Testing
@testable import CodexUsageCore

@Suite struct UsageModelTests {
    @Test func normalizesStandardWindows() {
        let model = UsageNormalizer.normalize(.init(
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 1_783_848_675),
            secondary: .init(usedPercent: 34, windowDurationMins: 10_080, resetsAt: 1_784_355_341)
        ))

        #expect(model.fiveHour.remainingPercent == 80)
        #expect(model.weekly.remainingPercent == 66)
        #expect(model.fiveHour.kind == .fiveHour)
        #expect(model.weekly.kind == .weekly)
    }

    @Test func clampsPercentagesAndIgnoresUnknownWindows() {
        let model = UsageNormalizer.normalize(.init(
            primary: .init(usedPercent: -5, windowDurationMins: 300),
            secondary: .init(usedPercent: 140, windowDurationMins: 10_080, resetsAt: 99),
            additional: [.init(usedPercent: 1, windowDurationMins: 60, resetsAt: 99)]
        ))

        #expect(model.fiveHour.remainingPercent == 100)
        #expect(model.weekly.remainingPercent == 0)
        #expect(model.fiveHour.resetsAt == nil)
    }

    @Test func marksMissingStandardWindowUnavailable() {
        let model = UsageNormalizer.normalize(.init(
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 100)
        ))

        #expect(model.fiveHour.freshness == .fresh)
        #expect(model.weekly.freshness == .unavailable)
        #expect(model.weekly.remainingPercent == nil)
    }

    @Test func sparseMergePreservesResetAndOtherWindow() {
        let current = RateLimitPayload(
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 100),
            secondary: .init(usedPercent: 34, windowDurationMins: 10_080, resetsAt: 200)
        )
        let update = RateLimitPatch(primary: .value(.init(usedPercent: .value(27))))

        guard case let .merged(merged) = UsageNormalizer.merge(current, update) else {
            Issue.record("Known sparse window update should merge")
            return
        }
        let model = UsageNormalizer.normalize(merged)

        #expect(model.fiveHour.remainingPercent == 73)
        #expect(model.fiveHour.resetsAt == 100)
        #expect(model.weekly.remainingPercent == 66)
        #expect(model.weekly.resetsAt == 200)
    }

    @Test func explicitNullResetClearsPreviousReset() {
        let current = RateLimitPayload(
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 100)
        )
        let update = RateLimitPatch(primary: .value(.init(resetsAt: .null)))

        guard case let .merged(merged) = UsageNormalizer.merge(current, update) else {
            Issue.record("Explicit reset null is safe to merge")
            return
        }

        #expect(merged.primary?.resetsAt == nil)
        #expect(UsageNormalizer.needsRefresh(UsageNormalizer.normalize(merged), now: 1))
    }

    @Test func identityChangeRequiresFullRefreshWithoutReusingFields() {
        let current = RateLimitPayload(
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 100)
        )
        let update = RateLimitPatch(primary: .value(.init(windowDurationMins: .value(10_080))))

        #expect(UsageNormalizer.merge(current, update) == .requiresFullRefresh(.windowIdentityChanged))
    }

    @Test func updateWithoutKnownWindowIdentityRequiresFullRefresh() {
        let current = RateLimitPayload(primary: .init(usedPercent: 20))
        let update = RateLimitPatch(primary: .value(.init(usedPercent: .value(27))))

        #expect(UsageNormalizer.merge(current, update) == .requiresFullRefresh(.unknownWindowIdentity))
    }

    @Test func addingIdentityToUnidentifiedExistingWindowRequiresFullRefresh() {
        let current = RateLimitPayload(
            primary: .init(usedPercent: 20, resetsAt: 100)
        )
        let update = RateLimitPatch(
            primary: .value(.init(windowDurationMins: .value(10_080)))
        )

        #expect(UsageNormalizer.merge(current, update) == .requiresFullRefresh(.unknownWindowIdentity))
    }

    @Test func refreshesForDueOrUnavailableWindows() {
        let model = UsageNormalizer.normalize(.init(
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 100),
            secondary: .init(usedPercent: 34, windowDurationMins: 10_080, resetsAt: 200)
        ))

        #expect(!UsageNormalizer.needsRefresh(model, now: 99))
        #expect(UsageNormalizer.needsRefresh(model, now: 100))
        #expect(UsageNormalizer.needsRefresh(.unavailable, now: 1))
    }

    @Test func formatsLocalResetDateAndTimeWithoutChangingSnapshot() {
        let fiveHourReset: Int64 = 1_783_848_675
        let weeklyReset: Int64 = 1_784_355_341
        let snapshot = UsageNormalizer.normalize(.init(
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: fiveHourReset),
            secondary: .init(usedPercent: 34, windowDurationMins: 10_080, resetsAt: weeklyReset)
        ))

        let locale = Locale(identifier: "en_US")
        let utc = TimeZone(identifier: "UTC")!
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!

        let fiveHourUTC = ResetTimeFormatter.format(fiveHourReset, locale: locale, timeZone: utc)
        let fiveHourShanghai = ResetTimeFormatter.format(fiveHourReset, locale: locale, timeZone: shanghai)
        let weeklyUTC = ResetTimeFormatter.format(weeklyReset, locale: locale, timeZone: utc)
        let weeklyChinese = ResetTimeFormatter.format(
            weeklyReset,
            includesWeekday: true,
            locale: Locale(identifier: "zh_CN"),
            timeZone: utc
        )

        #expect(fiveHourUTC?.contains("7/12/26") == true)
        #expect(fiveHourUTC?.contains("9:31") == true)
        #expect(fiveHourShanghai?.contains("7/12/26") == true)
        #expect(fiveHourShanghai?.contains("5:31") == true)
        #expect(weeklyUTC?.contains("7/18/26") == true)
        #expect(weeklyUTC?.contains("6:15") == true)
        #expect(weeklyChinese?.contains("7月18日") == true)
        #expect(weeklyChinese?.contains("周六") == true)
        #expect(snapshot.fiveHour.resetsAt == fiveHourReset)
        #expect(snapshot.weekly.resetsAt == weeklyReset)
        #expect(snapshot.fiveHour.remainingPercent == 80)
    }
}
