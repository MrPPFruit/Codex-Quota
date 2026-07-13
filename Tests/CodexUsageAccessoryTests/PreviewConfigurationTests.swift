import AppKit
@testable import CodexUsageAccessory
import CodexUsageCore
import CodexUsageUI
import Testing

@Test func previewIsDisabledUnlessExplicitlyEnabled() {
    #expect(AccessoryPreviewConfiguration.parse(environment: [:]) == nil)
    #expect(AccessoryPreviewConfiguration.parse(environment: ["CODEX_ACCESSORY_PREVIEW_MODE": "0"]) == nil)
}

@Test func previewParsesFixtureAndValidationPolicy() throws {
    let configuration = try #require(AccessoryPreviewConfiguration.parse(environment: [
        "CODEX_ACCESSORY_PREVIEW_MODE": "1",
        "CODEX_ACCESSORY_PREVIEW_STATE": "urgent",
        "CODEX_ACCESSORY_PREVIEW_APPEARANCE": "dark",
        "CODEX_ACCESSORY_PREVIEW_REDUCE_MOTION": "1",
        "CODEX_ACCESSORY_PREVIEW_REDUCE_TRANSPARENCY": "1",
        "CODEX_ACCESSORY_PREVIEW_EXPANDED": "1",
        "CODEX_ACCESSORY_PREVIEW_AUTO_EXIT_SECONDS": "12",
    ]))

    #expect(configuration.state == .urgent)
    #expect(configuration.appearance == .dark)
    #expect(configuration.reduceMotionOverride == true)
    #expect(configuration.reduceTransparencyOverride == true)
    #expect(configuration.expanded)
    #expect(configuration.autoExitSeconds == 12)
    #expect(configuration.snapshot.fiveHour.remainingPercent == 16)
    #expect(configuration.snapshot.weekly.remainingPercent == 18)
    #expect(configuration.snapshot.fiveHour.freshness == .fresh)
}

@Test func previewUnknownStateFailsClosedToUnavailable() throws {
    let configuration = try #require(AccessoryPreviewConfiguration.parse(environment: [
        "CODEX_ACCESSORY_PREVIEW_MODE": "1",
        "CODEX_ACCESSORY_PREVIEW_STATE": "invented",
    ]))

    #expect(configuration.state == .unavailable)
    #expect(configuration.snapshot == .unavailable)
}

@Test func previewFixturesCoverEverySemanticStateWithoutPersonalData() {
    let expected: [(AccessoryPreviewState, Double?, Double?)] = [
        (.sufficient, 80, 82),
        (.nearFull, 93, 66),
        (.full, 100, 66),
        (.attention, 42, 44),
        (.urgent, 16, 18),
        (.weeklyFallback, nil, 66),
        (.unavailable, nil, nil),
    ]
    for (state, fiveHourPercent, weeklyPercent) in expected {
        let snapshot = state.snapshot
        #expect(snapshot.fiveHour.remainingPercent == fiveHourPercent)
        #expect(snapshot.weekly.remainingPercent == weeklyPercent)
    }
    #expect(AccessoryPreviewState.weeklyFallback.snapshot.weekly.remainingPercent == 66)
    #expect(CollapsedUsagePresentation.select(from: AccessoryPreviewState.weeklyFallback.snapshot).compactLabel == "本周")
}

@Test func previewAppearanceAndAutoExitAreStrictlyBounded() throws {
    let invalid = try #require(AccessoryPreviewConfiguration.parse(environment: [
        "CODEX_ACCESSORY_PREVIEW_MODE": "1",
        "CODEX_ACCESSORY_PREVIEW_APPEARANCE": "system",
        "CODEX_ACCESSORY_PREVIEW_AUTO_EXIT_SECONDS": "31",
    ]))
    #expect(invalid.appearance == nil)
    #expect(invalid.autoExitSeconds == nil)

    let minimum = try #require(AccessoryPreviewConfiguration.parse(environment: [
        "CODEX_ACCESSORY_PREVIEW_MODE": "1",
        "CODEX_ACCESSORY_PREVIEW_AUTO_EXIT_SECONDS": "1",
    ]))
    #expect(minimum.autoExitSeconds == 1)

    let strictFlags = try #require(AccessoryPreviewConfiguration.parse(environment: [
        "CODEX_ACCESSORY_PREVIEW_MODE": "1",
        "CODEX_ACCESSORY_PREVIEW_REDUCE_MOTION": "true",
        "CODEX_ACCESSORY_PREVIEW_EXPANDED": "true",
    ]))
    #expect(strictFlags.reduceMotionOverride == nil)
    #expect(strictFlags.expanded == false)
}

@MainActor
@Test func previewAppearanceOnlyChangesTheExplicitPanel() throws {
    let configuration = try #require(AccessoryPreviewConfiguration.parse(environment: [
        "CODEX_ACCESSORY_PREVIEW_MODE": "1",
        "CODEX_ACCESSORY_PREVIEW_APPEARANCE": "light",
    ]))
    let panel = OverlayPanel()

    configuration.applyAppearance(panel: panel)

    #expect(panel.appearance?.name == .aqua)
}
