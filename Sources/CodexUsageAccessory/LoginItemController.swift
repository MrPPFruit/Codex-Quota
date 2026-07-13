import Foundation
import ServiceManagement

public enum LoginItemEligibility {
    public static let expectedBundleIdentifier = "com.ppfruit.codex-quota"

    public static func isStableInstallation(
        bundleURL: URL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard bundleURL.pathExtension == "app",
              bundleIdentifier == expectedBundleIdentifier else { return false }
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let allowedRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return allowedRoots.contains { bundle.hasPrefix($0 + "/") }
    }
}

public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LoginItemServicing: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
public final class SystemLoginItemService: LoginItemServicing {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
public final class DisabledLoginItemService: LoginItemServicing {
    public init() {}
    public var status: LoginItemStatus { .unavailable }
    public func register() throws {}
    public func unregister() throws {}
    public func openSystemSettings() {}
}

public struct LoginItemPresentation: Sendable, Equatable {
    public let title: String
    public let state: Int
    public let isEnabled: Bool

    public init(title: String, state: Int, isEnabled: Bool) {
        self.title = title
        self.state = state
        self.isEnabled = isEnabled
    }
}

@MainActor
public final class LoginItemController {
    public static let attemptedKey = "codex-quota.login-item.initial-registration-attempted"
    public static let optOutKey = "codex-quota.login-item.user-opted-out"

    private let service: any LoginItemServicing
    private let defaults: UserDefaults
    private let allowsMutations: Bool
    private var operationFailed = false

    public init(
        service: any LoginItemServicing,
        defaults: UserDefaults = .standard,
        allowsMutations: Bool
    ) {
        self.service = service
        self.defaults = defaults
        self.allowsMutations = allowsMutations
    }

    public func prepareForLaunch() {
        guard allowsMutations,
              service.status == .notRegistered,
              defaults.bool(forKey: Self.attemptedKey) == false,
              defaults.bool(forKey: Self.optOutKey) == false else { return }
        defaults.set(true, forKey: Self.attemptedKey)
        do {
            try service.register()
            operationFailed = false
        } catch {
            operationFailed = true
        }
    }

    public func performMenuAction() {
        guard allowsMutations else { return }
        do {
            switch service.status {
            case .enabled:
                defaults.set(true, forKey: Self.optOutKey)
                try service.unregister()
            case .notRegistered:
                defaults.set(true, forKey: Self.attemptedKey)
                defaults.set(false, forKey: Self.optOutKey)
                try service.register()
            case .requiresApproval:
                service.openSystemSettings()
            case .unavailable:
                return
            }
            operationFailed = false
        } catch {
            operationFailed = true
        }
    }

    public var presentation: LoginItemPresentation {
        guard allowsMutations else {
            return LoginItemPresentation(title: "登录时启动（不可用）", state: 0, isEnabled: false)
        }
        switch service.status {
        case .enabled:
            return LoginItemPresentation(title: "登录时启动", state: 1, isEnabled: true)
        case .notRegistered:
            let title = operationFailed ? "登录时启动（重试）" : "登录时启动"
            return LoginItemPresentation(title: title, state: 0, isEnabled: true)
        case .requiresApproval:
            return LoginItemPresentation(title: "登录时启动（需要批准）", state: -1, isEnabled: true)
        case .unavailable:
            return LoginItemPresentation(title: "登录时启动（不可用）", state: 0, isEnabled: false)
        }
    }
}
