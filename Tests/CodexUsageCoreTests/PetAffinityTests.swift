import CoreGraphics
import CodexUsageCore
import Foundation
import Testing

private let codexBundleID = "com.openai.codex"

@Test func windowSnapshotContainsOnlyRedactedMetadata() {
    let snapshot = window(id: 1, bounds: CGRect(x: 20, y: 20, width: 240, height: 240))
    let labels = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))

    #expect(labels == [
        "windowID", "ownerPID", "bundleIdentifier", "layer", "alpha", "bounds",
        "sharingState", "isOnScreen", "nameFieldPresent",
    ])
}

@Test func uniqueAllowlistedIdentityWithReliableExclusionsAttaches() {
    let pet = window(id: 1, layer: 3, bounds: CGRect(x: 300, y: 300, width: 240, height: 240))
    let overlay = window(id: 2, layer: 8, bounds: CGRect(x: 550, y: 300, width: 180, height: 80))

    let decision = PetAffinityDecision.decide(
        snapshots: [pet, overlay],
        identityRule: .allowlistedMetadata(.init(bundleIdentifier: codexBundleID, layer: 3, sharingState: 1, requiresNameField: true))
    )

    #expect(decision == .attached(pet: pet.bounds!, exclusions: [overlay.bounds!]))
}

@Test(arguments: [0, 2])
func zeroOrMultipleCandidatesStayIndependent(candidateCount: Int) {
    let candidates = (0..<candidateCount).map {
        window(id: UInt32($0 + 1), layer: 3, bounds: CGRect(x: $0 * 260, y: 200, width: 240, height: 240))
    }
    let decision = PetAffinityDecision.decide(
        snapshots: candidates,
        identityRule: .allowlistedMetadata(.init(bundleIdentifier: codexBundleID, layer: 3, sharingState: 1, requiresNameField: true))
    )

    #expect(decision == .independent(candidateCount == 0 ? .noCandidate : .ambiguousCandidates))
}

@Test func missingIdentityMetadataStaysIndependent() {
    let candidate = window(id: 1, layer: nil, bounds: CGRect(x: 200, y: 200, width: 240, height: 240))
    let decision = PetAffinityDecision.decide(
        snapshots: [candidate],
        identityRule: .allowlistedMetadata(.init(bundleIdentifier: codexBundleID, layer: 3, sharingState: 1, requiresNameField: true))
    )

    #expect(decision == .independent(.missingIdentityMetadata))
}

@Test func missingOnScreenMetadataStaysIndependent() {
    let candidate = window(
        id: 1,
        bounds: CGRect(x: 200, y: 200, width: 240, height: 240),
        isOnScreen: nil
    )
    let decision = PetAffinityDecision.decide(
        snapshots: [candidate],
        identityRule: .allowlistedMetadata(.init(bundleIdentifier: codexBundleID, layer: 3, sharingState: 1, requiresNameField: true))
    )

    #expect(decision == .independent(.missingIdentityMetadata))
}

@Test func unknownNearbyCodexSurfaceStaysIndependent() {
    let pet = window(id: 1, layer: 3, bounds: CGRect(x: 300, y: 300, width: 240, height: 240))
    let unknown = window(id: 2, layer: 8, bounds: nil)
    let decision = PetAffinityDecision.decide(
        snapshots: [pet, unknown],
        identityRule: .allowlistedMetadata(.init(bundleIdentifier: codexBundleID, layer: 3, sharingState: 1, requiresNameField: true))
    )

    #expect(decision == .independent(.unknownNearbySurface))
}

@Test func codexSurfaceWithUnknownOnScreenStateBlocksAttachment() {
    let pet = window(id: 1, layer: 3, bounds: CGRect(x: 300, y: 300, width: 240, height: 240))
    let unknownOverlay = window(
        id: 2,
        layer: 8,
        bounds: CGRect(x: 550, y: 300, width: 180, height: 80),
        isOnScreen: nil
    )
    let decision = PetAffinityDecision.decide(
        snapshots: [pet, unknownOverlay],
        identityRule: .allowlistedMetadata(.init(bundleIdentifier: codexBundleID, layer: 3, sharingState: 1, requiresNameField: true))
    )

    #expect(decision == .independent(.missingIdentityMetadata))
}

@Test func possibleTrayWithoutExclusionBoundsStaysIndependent() {
    let pet = window(id: 1, layer: 3, bounds: CGRect(x: 300, y: 300, width: 240, height: 240))
    let decision = PetAffinityDecision.decide(
        snapshots: [pet],
        identityRule: .allowlistedMetadata(.init(bundleIdentifier: codexBundleID, layer: 3, sharingState: 1, requiresNameField: true)),
        trayRisk: .possibleWithoutBounds
    )

    #expect(decision == .independent(.unboundedTrayRisk))
}

@Test func disabledProductionIdentityRuleStaysIndependent() {
    let petLikeSurface = window(id: 1, layer: 3, bounds: CGRect(x: 300, y: 300, width: 240, height: 240))
    #expect(PetAffinityDecision.decide(snapshots: [petLikeSurface], identityRule: .disabled) == .independent(.identityRuleUnavailable))
}

@Test func quartzBoundsConvertToAppKitGlobalCoordinatesAcrossDisplays() {
    let quartz = CGRect(x: -1_200, y: 1_000, width: 500, height: 400)
    #expect(WindowCoordinateConverter.appKitBounds(fromQuartz: quartz, mainDisplayMaxY: 900) ==
        CGRect(x: -1_200, y: -500, width: 500, height: 400))

    let aboveMain = CGRect(x: 200, y: -600, width: 300, height: 200)
    #expect(WindowCoordinateConverter.appKitBounds(fromQuartz: aboveMain, mainDisplayMaxY: 900) ==
        CGRect(x: 200, y: 1_300, width: 300, height: 200))
}

private func window(
    id: UInt32,
    layer: Int? = 3,
    bounds: CGRect?,
    sharingState: Int? = 1,
    nameFieldPresent: Bool = true,
    isOnScreen: Bool? = true
) -> WindowSnapshot {
    WindowSnapshot(
        windowID: id,
        ownerPID: 42,
        bundleIdentifier: codexBundleID,
        layer: layer,
        alpha: 1,
        bounds: bounds,
        sharingState: sharingState,
        isOnScreen: isOnScreen,
        nameFieldPresent: nameFieldPresent
    )
}
