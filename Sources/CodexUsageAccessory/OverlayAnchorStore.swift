import CoreGraphics
import Foundation

public protocol OverlayAnchorStoring: AnyObject {
    func load() -> CGPoint?
    func save(_ center: CGPoint)
}

public final class TransientOverlayAnchorStore: OverlayAnchorStoring {
    public init() {}
    public func load() -> CGPoint? { nil }
    public func save(_ center: CGPoint) {}
}

public final class UserDefaultsOverlayAnchorStore: OverlayAnchorStoring {
    private enum Key {
        static let x = "overlay.collapsedCenter.x"
        static let y = "overlay.collapsedCenter.y"
    }

    private static let maximumMagnitude: CGFloat = 1_000_000
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CGPoint? {
        guard defaults.object(forKey: Key.x) != nil, defaults.object(forKey: Key.y) != nil else { return nil }
        let center = CGPoint(x: defaults.double(forKey: Key.x), y: defaults.double(forKey: Key.y))
        guard Self.isValid(center) else { return nil }
        return center
    }

    public func save(_ center: CGPoint) {
        guard Self.isValid(center) else { return }
        defaults.set(Double(center.x), forKey: Key.x)
        defaults.set(Double(center.y), forKey: Key.y)
    }

    private static func isValid(_ center: CGPoint) -> Bool {
        center.x.isFinite && center.y.isFinite &&
            abs(center.x) <= maximumMagnitude && abs(center.y) <= maximumMagnitude
    }
}
