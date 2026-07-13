import CoreGraphics

public struct AllowlistedWindowIdentity: Sendable, Equatable {
    public let bundleIdentifier: String
    public let layer: Int
    public let sharingState: Int
    public let requiresNameField: Bool

    public init(bundleIdentifier: String, layer: Int, sharingState: Int, requiresNameField: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.sharingState = sharingState
        self.requiresNameField = requiresNameField
    }
}

public enum PetIdentityRule: Sendable, Equatable {
    case disabled
    case allowlistedMetadata(AllowlistedWindowIdentity)
}

public enum TrayRisk: Sendable, Equatable {
    case none
    case possibleWithoutBounds
}

public enum PetAffinityReason: String, Sendable, Equatable, Codable {
    case identityRuleUnavailable
    case missingIdentityMetadata
    case noCandidate
    case ambiguousCandidates
    case unknownNearbySurface
    case unboundedTrayRisk
}

public enum PetAffinityDecision: Sendable, Equatable {
    case attached(pet: CGRect, exclusions: [CGRect])
    case independent(PetAffinityReason)

    public static func decide(
        snapshots: [WindowSnapshot],
        identityRule: PetIdentityRule,
        trayRisk: TrayRisk = .none
    ) -> Self {
        guard trayRisk == .none else { return .independent(.unboundedTrayRisk) }
        guard case let .allowlistedMetadata(signature) = identityRule else {
            return .independent(.identityRuleUnavailable)
        }

        let owned = snapshots.filter { $0.bundleIdentifier == signature.bundleIdentifier }
        if owned.contains(where: { $0.isOnScreen == nil }) {
            return .independent(.missingIdentityMetadata)
        }
        let relevant = owned.filter { $0.isOnScreen == true }
        if relevant.contains(where: { snapshot in
            snapshot.layer == nil || snapshot.sharingState == nil
        }) {
            let possibleCandidate = relevant.contains {
                ($0.layer == nil || $0.layer == signature.layer) &&
                ($0.sharingState == nil || $0.sharingState == signature.sharingState)
            }
            if possibleCandidate { return .independent(.missingIdentityMetadata) }
        }

        let candidates = relevant.filter {
            $0.layer == signature.layer &&
            $0.sharingState == signature.sharingState &&
            (!signature.requiresNameField || $0.nameFieldPresent)
        }
        guard candidates.count == 1 else {
            return .independent(candidates.isEmpty ? .noCandidate : .ambiguousCandidates)
        }
        guard let pet = candidates[0].bounds, pet.isValidWindowBounds else {
            return .independent(.missingIdentityMetadata)
        }

        var exclusions: [CGRect] = []
        for snapshot in relevant where snapshot.windowID != candidates[0].windowID {
            guard let bounds = snapshot.bounds, bounds.isValidWindowBounds else {
                return .independent(.unknownNearbySurface)
            }
            exclusions.append(bounds)
        }
        return .attached(pet: pet, exclusions: exclusions)
    }
}

private extension CGRect {
    var isValidWindowBounds: Bool {
        !isNull && !isInfinite && width > 0 && height > 0 &&
        [minX, minY, width, height].allSatisfy(\.isFinite)
    }
}
