import CoreGraphics
import CodexUsageCore
import Testing

private let panel = CGSize(width: 100, height: 60)
private let visible = CGRect(x: 0, y: 0, width: 1_000, height: 800)

@Test func attachedPlacementTriesLeftThenRightTopBottom() {
    let pet = CGRect(x: 400, y: 300, width: 100, height: 100)

    #expect(OverlayPlacement.attached(panelSize: panel, visibleFrame: visible, petFrame: pet, exclusions: []) ==
        .placed(CGRect(x: 292, y: 320, width: 100, height: 60), direction: .left))

    let blockLeft = CGRect(x: 280, y: 300, width: 120, height: 100)
    #expect(OverlayPlacement.attached(panelSize: panel, visibleFrame: visible, petFrame: pet, exclusions: [blockLeft]) ==
        .placed(CGRect(x: 508, y: 320, width: 100, height: 60), direction: .right))

    let blockRight = CGRect(x: 500, y: 300, width: 120, height: 100)
    #expect(OverlayPlacement.attached(panelSize: panel, visibleFrame: visible, petFrame: pet, exclusions: [blockLeft, blockRight]) ==
        .placed(CGRect(x: 400, y: 408, width: 100, height: 60), direction: .top))

    let blockTop = CGRect(x: 390, y: 400, width: 120, height: 100)
    #expect(OverlayPlacement.attached(panelSize: panel, visibleFrame: visible, petFrame: pet, exclusions: [blockLeft, blockRight, blockTop]) ==
        .placed(CGRect(x: 400, y: 232, width: 100, height: 60), direction: .bottom))
}

@Test func everyExclusionRequiresAtLeastEightPointsClearance() {
    let pet = CGRect(x: 400, y: 300, width: 100, height: 100)
    let touchesInflatedLeftCandidate = CGRect(x: 391, y: 320, width: 1, height: 1)
    let secondExclusion = CGRect(x: 700, y: 700, width: 10, height: 10)

    #expect(OverlayPlacement.attached(
        panelSize: panel,
        visibleFrame: visible,
        petFrame: pet,
        exclusions: [secondExclusion, touchesInflatedLeftCandidate]
    ) == .placed(CGRect(x: 508, y: 320, width: 100, height: 60), direction: .right))
}

@Test func attachedPlacementNeverLeavesVisibleFrame() {
    let pet = CGRect(x: 0, y: 0, width: 100, height: 100)
    let result = OverlayPlacement.attached(panelSize: panel, visibleFrame: visible, petFrame: pet, exclusions: [])

    #expect(result == .placed(CGRect(x: 108, y: 20, width: 100, height: 60), direction: .right))
}

@Test func independentPlacementUsesRightBottomMarginAndNonzeroScreenOrigin() {
    let screen = CGRect(x: -1_200, y: 200, width: 1_000, height: 700)
    #expect(OverlayPlacement.independent(panelSize: panel, visibleFrame: screen) ==
        .placed(CGRect(x: -348, y: 248, width: 100, height: 60), direction: .independent))
}

@Test func independentPlacementClampsMarginsInNarrowVisibleFrame() {
    let narrow = CGRect(x: 50, y: 70, width: 120, height: 70)
    #expect(OverlayPlacement.independent(panelSize: panel, visibleFrame: narrow) ==
        .placed(CGRect(x: 50, y: 80, width: 100, height: 60), direction: .independent))
}

@Test func panelThatCannotFitReturnsExplicitFailure() {
    let tooSmall = CGRect(x: 0, y: 0, width: 90, height: 50)
    #expect(OverlayPlacement.independent(panelSize: panel, visibleFrame: tooSmall) == .failure(.panelDoesNotFit))
    #expect(OverlayPlacement.attached(panelSize: panel, visibleFrame: tooSmall, petFrame: .zero, exclusions: []) == .failure(.panelDoesNotFit))
}

@Test func invalidOrBlockedAttachedPlacementReturnsExplicitFailure() {
    let pet = CGRect(x: 100, y: 100, width: 100, height: 100)
    let cramped = CGRect(x: 90, y: 90, width: 120, height: 120)
    #expect(OverlayPlacement.attached(panelSize: panel, visibleFrame: cramped, petFrame: pet, exclusions: []) == .failure(.noSafeAttachedFrame))
}
