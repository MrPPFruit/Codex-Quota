import AppKit
import os

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
    private let logger = Logger(subsystem: "com.ppfruit.codex-quota", category: "presence")
    private let workspace: NSWorkspace
    private let refreshInterval: Duration
    private let bundleIdentifiers: @MainActor () -> [String?]
    private let observesWorkspaceChanges: Bool
    private var observation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var lastPresence: Bool?
    private var onChange: (@MainActor (Bool) -> Void)?

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        refreshInterval = .seconds(30)
        bundleIdentifiers = { workspace.runningApplications.map(\.bundleIdentifier) }
        observesWorkspaceChanges = true
    }

    init(
        refreshInterval: Duration,
        bundleIdentifiers: @escaping @MainActor () -> [String?]
    ) {
        workspace = .shared
        self.refreshInterval = refreshInterval
        self.bundleIdentifiers = bundleIdentifiers
        observesWorkspaceChanges = false
    }

    public var isMonitoring: Bool { observation != nil || refreshTask != nil }

    public func start(onChange: @escaping @MainActor (Bool) -> Void) {
        guard !isMonitoring else {
            logger.debug("monitor_start_ignored_already_active")
            return
        }
        logger.info("monitor_started")
        self.onChange = onChange
        if observesWorkspaceChanges {
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
        } else {
            refresh()
        }
        let interval = refreshInterval
        refreshTask = Task { @MainActor [weak self, interval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    public func refresh() { publish(bundleIdentifiers()) }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
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

    private func publish(_ bundleIdentifiers: [String?]) {
        let presence = CodexPresencePolicy.isRunning(bundleIdentifiers: bundleIdentifiers)
        if presence == lastPresence {
            guard presence else { return }
            logger.debug("presence_reconciled running=true")
            onChange?(true)
            return
        }
        lastPresence = presence
        logger.info("presence_changed running=\(presence, privacy: .public)")
        onChange?(presence)
    }

    isolated deinit {
        refreshTask?.cancel()
        observation?.invalidate()
        if let wakeObserver { workspace.notificationCenter.removeObserver(wakeObserver) }
        if let sessionObserver { workspace.notificationCenter.removeObserver(sessionObserver) }
    }
}
