import CodexUsageCore
import CodexUsageUI

public enum AccessoryLifecyclePhase: Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping
    case degraded
}

@MainActor
public final class AccessoryLifecycleCoordinator {
    public typealias SessionFactory = @MainActor (
        _ publishSnapshot: @escaping @MainActor (UsageSnapshot) -> Void
    ) async -> AccessoryUsageSession?

    private let store: UsageStore
    private let overlayController: OverlayController
    private let sessionFactory: SessionFactory
    private let retryDelay: @MainActor (_ failureCount: Int) async -> Void
    private let onPresenceChanged: @MainActor (Bool) -> Void
    private var desiredCodexPresence = false
    private var session: AccessoryUsageSession?
    private var reconcileTask: Task<Void, Never>?
    private var generation = 0
    private var recycleRequired = false

    public private(set) var phase: AccessoryLifecyclePhase = .idle

    public init(
        store: UsageStore,
        overlayController: OverlayController,
        sessionFactory: @escaping SessionFactory,
        retryDelay: @escaping @MainActor (_ failureCount: Int) async -> Void = AccessoryLifecycleCoordinator.defaultRetryDelay,
        onPresenceChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.store = store
        self.overlayController = overlayController
        self.sessionFactory = sessionFactory
        self.retryDelay = retryDelay
        self.onPresenceChanged = onPresenceChanged
    }

    public func setCodexRunning(_ isRunning: Bool) {
        if !isRunning, session != nil || phase == .starting {
            recycleRequired = true
        }
        desiredCodexPresence = isRunning
        overlayController.setLifecycleAvailable(isRunning)
        onPresenceChanged(isRunning)
        if !isRunning { store.snapshot = .unavailable }
        if !isRunning, phase == .starting {
            reconcileTask?.cancel()
        }
        scheduleReconcile()
    }

    public func shutdownForQuit() async throws {
        desiredCodexPresence = false
        overlayController.setLifecycleAvailable(false)
        store.snapshot = .unavailable
        if phase == .starting { reconcileTask?.cancel() }
        if phase == .degraded {
            guard let session else { phase = .idle; return }
            phase = .stopping
            do { try await session.shutdown() }
            catch { phase = .degraded; throw error }
            self.session = nil
            generation += 1
            phase = .idle
            return
        }
        scheduleReconcile()
        await reconcileTask?.value
        if phase == .degraded { throw AppServerClientError.cleanupFailure }
    }

    private func scheduleReconcile() {
        guard reconcileTask == nil, phase != .degraded else { return }
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainDesiredState()
            self.reconcileTask = nil
            let stillNeedsReconcile = self.phase != .degraded && (
                (self.desiredCodexPresence && self.session == nil) ||
                (!self.desiredCodexPresence && self.session != nil)
            )
            if stillNeedsReconcile { self.scheduleReconcile() }
        }
    }

    private func drainDesiredState() async {
        var consecutiveStartFailures = 0
        while true {
            if desiredCodexPresence, session == nil {
                recycleRequired = false
                phase = .starting
                generation += 1
                let requestedGeneration = generation
                let candidate = await sessionFactory { [weak self] snapshot in
                    guard let self,
                          self.generation == requestedGeneration,
                          self.desiredCodexPresence else { return }
                    self.store.snapshot = snapshot
                }
                if Task.isCancelled {
                    if let candidate, !(await discard(candidate)) { return }
                    phase = .idle
                    return
                }
                guard requestedGeneration == generation else {
                    if let candidate, !(await discard(candidate)) { return }
                    continue
                }
                guard desiredCodexPresence else {
                    if let candidate, !(await discard(candidate)) { return }
                    phase = .idle
                    return
                }
                guard let candidate else {
                    guard desiredCodexPresence, !Task.isCancelled else { return }
                    consecutiveStartFailures += 1
                    await retryDelay(consecutiveStartFailures)
                    guard desiredCodexPresence, !Task.isCancelled else {
                        phase = .idle
                        return
                    }
                    continue
                }
                consecutiveStartFailures = 0
                session = candidate
                await candidate.start()
                guard desiredCodexPresence else { continue }
                phase = .running
                return
            }

            if (!desiredCodexPresence || recycleRequired), let activeSession = session {
                phase = .stopping
                generation += 1
                do { try await activeSession.shutdown() }
                catch {
                    phase = .degraded
                    store.snapshot = .unavailable
                    return
                }
                session = nil
                recycleRequired = false
                phase = .idle
                store.snapshot = .unavailable
                if desiredCodexPresence { continue }
                return
            }

            phase = session == nil ? .idle : .running
            return
        }
    }

    public static func defaultRetryDelay(failureCount: Int) async {
        let exponent = min(max(failureCount - 1, 0), 4)
        let milliseconds = min(250 * (1 << exponent), 4_000)
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func discard(_ candidate: AccessoryUsageSession) async -> Bool {
        do {
            try await candidate.shutdown()
            return true
        } catch {
            session = candidate
            phase = .degraded
            store.snapshot = .unavailable
            return false
        }
    }
}
