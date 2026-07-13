import Foundation

public protocol OverlayVisibilityStoring: AnyObject {
    func load() -> Bool
    func save(_ isEnabled: Bool)
}

public final class UserDefaultsOverlayVisibilityStore: OverlayVisibilityStoring {
    public static let key = "codex-quota.show-overlay-when-codex-runs"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> Bool {
        defaults.object(forKey: Self.key) == nil ? true : defaults.bool(forKey: Self.key)
    }

    public func save(_ isEnabled: Bool) { defaults.set(isEnabled, forKey: Self.key) }
}

public final class TransientOverlayVisibilityStore: OverlayVisibilityStoring {
    private var isEnabled: Bool
    public init(isEnabled: Bool = true) { self.isEnabled = isEnabled }
    public func load() -> Bool { isEnabled }
    public func save(_ isEnabled: Bool) { self.isEnabled = isEnabled }
}
