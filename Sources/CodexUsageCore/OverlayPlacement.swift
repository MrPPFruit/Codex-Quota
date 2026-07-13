import CoreGraphics

public enum OverlayPlacementDirection: Sendable, Equatable {
    case left, right, top, bottom, independent
}

public enum OverlayPlacementFailure: Sendable, Equatable {
    case invalidGeometry
    case panelDoesNotFit
    case noSafeAttachedFrame
}

public enum OverlayPlacementResult: Sendable, Equatable {
    case placed(CGRect, direction: OverlayPlacementDirection)
    case failure(OverlayPlacementFailure)
}

public enum OverlayPlacement {
    public static let clearance: CGFloat = 8
    public static let independentMargin: CGFloat = 48

    public static func attached(
        panelSize: CGSize,
        visibleFrame: CGRect,
        petFrame: CGRect,
        exclusions: [CGRect]
    ) -> OverlayPlacementResult {
        guard geometryIsValid(panelSize: panelSize, visibleFrame: visibleFrame) else { return .failure(.invalidGeometry) }
        guard panelSize.width <= visibleFrame.width, panelSize.height <= visibleFrame.height else {
            return .failure(.panelDoesNotFit)
        }
        guard petFrame.isUsable, exclusions.allSatisfy(\.isUsable) else { return .failure(.invalidGeometry) }

        let centeredY = petFrame.midY - panelSize.height / 2
        let centeredX = petFrame.midX - panelSize.width / 2
        let candidates: [(CGRect, OverlayPlacementDirection)] = [
            (CGRect(x: petFrame.minX - clearance - panelSize.width, y: centeredY, width: panelSize.width, height: panelSize.height), .left),
            (CGRect(x: petFrame.maxX + clearance, y: centeredY, width: panelSize.width, height: panelSize.height), .right),
            (CGRect(x: centeredX, y: petFrame.maxY + clearance, width: panelSize.width, height: panelSize.height), .top),
            (CGRect(x: centeredX, y: petFrame.minY - clearance - panelSize.height, width: panelSize.width, height: panelSize.height), .bottom),
        ]
        for (frame, direction) in candidates where visibleFrame.contains(frame) {
            let blocked = exclusions.contains { frame.intersects($0.insetBy(dx: -clearance, dy: -clearance)) }
            if !blocked { return .placed(frame, direction: direction) }
        }
        return .failure(.noSafeAttachedFrame)
    }

    public static func independent(panelSize: CGSize, visibleFrame: CGRect) -> OverlayPlacementResult {
        guard geometryIsValid(panelSize: panelSize, visibleFrame: visibleFrame) else { return .failure(.invalidGeometry) }
        guard panelSize.width <= visibleFrame.width, panelSize.height <= visibleFrame.height else {
            return .failure(.panelDoesNotFit)
        }
        let maximumX = visibleFrame.maxX - panelSize.width
        let maximumY = visibleFrame.maxY - panelSize.height
        let x = min(maximumX, max(visibleFrame.minX, maximumX - independentMargin))
        let y = min(maximumY, max(visibleFrame.minY, visibleFrame.minY + independentMargin))
        return .placed(CGRect(origin: CGPoint(x: x, y: y), size: panelSize), direction: .independent)
    }

    private static func geometryIsValid(panelSize: CGSize, visibleFrame: CGRect) -> Bool {
        panelSize.width.isFinite && panelSize.height.isFinite && panelSize.width > 0 && panelSize.height > 0 && visibleFrame.isUsable
    }
}

private extension CGRect {
    var isUsable: Bool {
        !isNull && !isInfinite && width > 0 && height > 0 &&
        [minX, minY, width, height].allSatisfy(\.isFinite)
    }
}
