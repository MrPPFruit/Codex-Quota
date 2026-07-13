import CoreGraphics

public struct WindowSnapshot: Sendable, Equatable {
    public let windowID: UInt32
    public let ownerPID: Int32
    public let bundleIdentifier: String?
    public let layer: Int?
    public let alpha: Double?
    public let bounds: CGRect?
    public let sharingState: Int?
    public let isOnScreen: Bool?
    public let nameFieldPresent: Bool

    public init(
        windowID: UInt32,
        ownerPID: Int32,
        bundleIdentifier: String?,
        layer: Int?,
        alpha: Double?,
        bounds: CGRect?,
        sharingState: Int?,
        isOnScreen: Bool?,
        nameFieldPresent: Bool
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
        self.sharingState = sharingState
        self.isOnScreen = isOnScreen
        self.nameFieldPresent = nameFieldPresent
    }
}

public enum WindowCoordinateConverter {
    public static func appKitBounds(fromQuartz bounds: CGRect, mainDisplayMaxY: CGFloat) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: mainDisplayMaxY - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }
}
