import CodexUsageCore
import CodexUsageUI
import Foundation
import Testing

@Test func bubbleAppearancePresetsKeepTheApprovedParametersAndDefault() {
    #expect(BubbleAppearancePreset.defaultValue == .soft)
    #expect(BubbleAppearancePreset.allCases.map(\.displayName) == ["清透", "柔彩"])
    let clear = BubbleAppearancePreset.clear.parameters
    #expect(clear.whiteLayerOpacity == 0.20)
    #expect(clear.colorLayerOpacity == 0.40)
    #expect(clear.saturation == 1.70)
    #expect(clear.brightness == 0.10)
    #expect(clear.blurRadius == 7.0)
    let soft = BubbleAppearancePreset.soft.parameters
    #expect(soft.whiteLayerOpacity == 0.70)
    #expect(soft.colorLayerOpacity == 0.60)
    #expect(soft.saturation == 1.60)
    #expect(soft.brightness == -0.10)
    #expect(soft.blurRadius == 8.0)
}

@Test func bubbleAppearancePresetRestoresValidSelectionsAndFallsBackToSoft() {
    #expect(BubbleAppearancePreset.resolve(storedRawValue: nil) == .soft)
    #expect(BubbleAppearancePreset.resolve(storedRawValue: "invalid") == .soft)
    #expect(BubbleAppearancePreset.resolve(storedRawValue: BubbleAppearancePreset.clear.rawValue) == .clear)
    #expect(BubbleAppearancePreset.resolve(storedRawValue: BubbleAppearancePreset.soft.rawValue) == .soft)
}

@Test func bubbleAppearancePresetPersistsAcrossDefaultsInstances() throws {
    let suiteName = "BubbleAppearancePresetTests.\(UUID().uuidString)"
    let first = try #require(UserDefaults(suiteName: suiteName))
    defer { first.removePersistentDomain(forName: suiteName) }

    #expect(BubbleAppearancePreset.resolve(
        storedRawValue: first.string(forKey: BubbleAppearancePreset.storageKey)
    ) == .soft)

    first.set(BubbleAppearancePreset.clear.rawValue, forKey: BubbleAppearancePreset.storageKey)
    let restartedWithClear = try #require(UserDefaults(suiteName: suiteName))
    #expect(BubbleAppearancePreset.resolve(
        storedRawValue: restartedWithClear.string(forKey: BubbleAppearancePreset.storageKey)
    ) == .clear)

    restartedWithClear.set(BubbleAppearancePreset.soft.rawValue, forKey: BubbleAppearancePreset.storageKey)
    let restartedWithSoft = try #require(UserDefaults(suiteName: suiteName))
    #expect(BubbleAppearancePreset.resolve(
        storedRawValue: restartedWithSoft.string(forKey: BubbleAppearancePreset.storageKey)
    ) == .soft)
}

@Test func visibleQuotaTextUsesOnlyTheRoundedNumber() {
    let available = UsageWindow(kind: .fiveHour, remainingPercent: 79.6, resetsAt: nil, freshness: .fresh)
    let unavailable = UsageWindow(kind: .weekly, remainingPercent: nil, resetsAt: nil, freshness: .unavailable)

    #expect(UsageVisibleQuotaText.make(for: available) == "80")
    #expect(UsageVisibleQuotaText.make(for: unavailable) == "--")
}

@Test(arguments: [
    (0.0, UsageSemanticLevel.urgent),
    (19.999, UsageSemanticLevel.urgent),
    (20.0, UsageSemanticLevel.attention),
    (80.0, UsageSemanticLevel.sufficient),
    (40.0, UsageSemanticLevel.attention),
    (59.999, UsageSemanticLevel.attention),
    (60.0, UsageSemanticLevel.sufficient),
    (100.0, UsageSemanticLevel.sufficient),
])
func semanticThresholds(percent: Double, expected: UsageSemanticLevel) {
    #expect(UsageSemanticStyle.level(for: percent) == expected)
}

@Test func eachWindowKeepsItsOwnSemanticLevel() {
    let style = UsageSemanticStyle(fiveHourPercent: 80, weeklyPercent: 16)

    #expect(style.fiveHour == .sufficient)
    #expect(style.weekly == .urgent)
}

@Test func unavailableIsGray() {
    let style = UsageSemanticStyle(fiveHourPercent: nil, weeklyPercent: nil)

    #expect(style.fiveHour == .unavailable)
    #expect(style.weekly == .unavailable)
}

@Test func accessibilityUsesTheSameBoundaryMeanings() {
    let urgent = UsageAccessibilityDescriptor(window: .init(kind: .fiveHour, remainingPercent: 19.999, resetsAt: nil, freshness: .fresh))
    let attention = UsageAccessibilityDescriptor(window: .init(kind: .fiveHour, remainingPercent: 20, resetsAt: nil, freshness: .fresh))
    let sufficient = UsageAccessibilityDescriptor(window: .init(kind: .fiveHour, remainingPercent: 60, resetsAt: nil, freshness: .fresh))

    #expect(urgent.value.hasSuffix("紧张"))
    #expect(attention.value.hasSuffix("注意"))
    #expect(sufficient.value.hasSuffix("充足"))
}

@Test func accessibilityDescriptorsExposeValueAndNonColorMeaning() {
    let sufficient = UsageAccessibilityDescriptor(window: .init(kind: .fiveHour, remainingPercent: 80, resetsAt: nil, freshness: .fresh))
    let unavailable = UsageAccessibilityDescriptor(window: .init(kind: .weekly, remainingPercent: nil, resetsAt: nil, freshness: .unavailable))

    #expect(sufficient.label == "5小时额度")
    #expect(sufficient.value == "剩余80%，充足")
    #expect(unavailable.label == "本周额度")
    #expect(unavailable.value == "不可用")
}

@Test func collapsedUsagePrefersFiveHourThenFallsBackToWeeklyAsOnePresentation() {
    let bothAvailable = UsageSnapshot(
        fiveHour: .init(kind: .fiveHour, remainingPercent: 80, resetsAt: nil, freshness: .fresh),
        weekly: .init(kind: .weekly, remainingPercent: 66, resetsAt: nil, freshness: .fresh)
    )
    let weeklyFallback = UsageSnapshot(
        fiveHour: .init(kind: .fiveHour, remainingPercent: nil, resetsAt: nil, freshness: .unavailable),
        weekly: .init(kind: .weekly, remainingPercent: 42, resetsAt: nil, freshness: .fresh)
    )

    let primary = CollapsedUsagePresentation.select(from: bothAvailable)
    #expect(primary.window.kind == .fiveHour)
    #expect(primary.compactLabel == "5h")
    #expect(primary.semanticLevel == .sufficient)
    #expect(primary.accessibilityLabel == "5小时额度")

    let fallback = CollapsedUsagePresentation.select(from: weeklyFallback)
    #expect(fallback.window.kind == .weekly)
    #expect(fallback.compactLabel == "本周")
    #expect(fallback.semanticLevel == .attention)
    #expect(fallback.accessibilityLabel == "本周额度")
    #expect(fallback.accessibilityValue == "剩余42%，注意")
}

@Test func collapsedUsageFailsClosedWhenNeitherWindowIsDisplayable() {
    let presentation = CollapsedUsagePresentation.select(from: .unavailable)

    #expect(presentation.compactLabel == "额度")
    #expect(presentation.semanticLevel == .unavailable)
    #expect(presentation.accessibilityLabel == "额度")
    #expect(presentation.accessibilityValue == "不可用")
}

@Test func compactResetKeepsAbsoluteDateWeekdayAndTimeAcrossLocales() throws {
    let reset: Int64 = 1_893_715_200
    let weekly = UsageWindow(kind: .weekly, remainingPercent: 66, resetsAt: reset, freshness: .fresh)
    let fiveHour = UsageWindow(kind: .fiveHour, remainingPercent: 93, resetsAt: reset, freshness: .fresh)
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let zh = CompactResetPresentation.make(for: weekly, locale: Locale(identifier: "zh_CN"), timeZone: timeZone)
    let en = CompactResetPresentation.make(for: weekly, locale: Locale(identifier: "en_US"), timeZone: timeZone)
    let short = CompactResetPresentation.make(for: fiveHour, locale: Locale(identifier: "zh_CN"), timeZone: timeZone)

    #expect(zh.date.contains("周"))
    #expect(zh.time.isEmpty == false)
    #expect(en.date.isEmpty == false)
    #expect(en.time.isEmpty == false)
    #expect(short.date.contains("周") == false)
}

@Test func compactResetFailsClosedWithoutAUsableReset() {
    let window = UsageWindow(kind: .weekly, remainingPercent: nil, resetsAt: nil, freshness: .unavailable)
    #expect(CompactResetPresentation.make(for: window) == .init(date: "重置", time: "不可用"))
}

@MainActor
@Test func storeConsumesUpdateAndDisconnectFromOneSnapshotStream() async throws {
    let store = UsageStore()
    var continuation: AsyncStream<UsageSnapshot>.Continuation!
    let stream = AsyncStream<UsageSnapshot> { continuation = $0 }
    let observation = Task { await store.observe(stream) }
    let connected = UsageSnapshot(
        fiveHour: .init(kind: .fiveHour, remainingPercent: 73, resetsAt: nil, freshness: .fresh),
        weekly: .init(kind: .weekly, remainingPercent: 66, resetsAt: nil, freshness: .fresh)
    )

    continuation.yield(connected)
    try await eventuallyUI { store.snapshot == connected }
    continuation.yield(.unavailable)
    try await eventuallyUI { store.snapshot == .unavailable }
    continuation.finish()
    await observation.value
}

@MainActor
private func eventuallyUI(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition did not become true")
}
