import AppKit

public enum CodexPresencePolicy {
    public static let bundleIdentifier = "com.openai.codex"

    public static func isRunning(bundleIdentifiers: [String?]) -> Bool {
        bundleIdentifiers.contains(Self.bundleIdentifier)
    }
}

@MainActor
public protocol CodexPresenceMonitoring: AnyObject {
    var isMonitoring: Bool { get }
    func start(onChange: @escaping @MainActor (Bool) -> Void)
    func refresh()
    func stop()
}

@MainActor
public final class SystemCodexPresenceMonitor: CodexPresenceMonitoring {
    private let workspace: NSWorkspace
    private var observation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?
    private var lastPresence: Bool?
    private var onChange: (@MainActor (Bool) -> Void)?

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public var isMonitoring: Bool { observation != nil }

    public func start(onChange: @escaping @MainActor (Bool) -> Void) {
        guard observation == nil else { return }
        self.onChange = onChange
        observation = workspace.observe(\.runningApplications, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let center = workspace.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        sessionObserver = center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    public func refresh() { publish(workspace.runningApplications) }

    public func stop() {
        observation?.invalidate()
        observation = nil
        let center = workspace.notificationCenter
        if let wakeObserver { center.removeObserver(wakeObserver) }
        if let sessionObserver { center.removeObserver(sessionObserver) }
        wakeObserver = nil
        sessionObserver = nil
        onChange = nil
        lastPresence = nil
    }

    private func publish(_ applications: [NSRunningApplication]) {
        let presence = CodexPresencePolicy.isRunning(bundleIdentifiers: applications.map(\.bundleIdentifier))
        guard presence != lastPresence else { return }
        lastPresence = presence
        onChange?(presence)
    }

    isolated deinit {
        observation?.invalidate()
        if let wakeObserver { workspace.notificationCenter.removeObserver(wakeObserver) }
        if let sessionObserver { workspace.notificationCenter.removeObserver(sessionObserver) }
    }
}
