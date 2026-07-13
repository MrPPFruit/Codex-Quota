import CodexUsageCore
import CodexUsageUI

public enum AccessoryUsageLifecycle: Sendable, Equatable {
    case idle
    case starting
    case running
    case shuttingDown
    case stopped
}

@MainActor
public final class AccessoryUsageSession {
    private let client: any UsageStreamingClient
    private let publishSnapshot: @MainActor (UsageSnapshot) -> Void
    private var connectionTask: Task<Void, Never>?
    private let retryDelays: [Duration]
    private var shutdownTask: Task<Void, Error>?

    public private(set) var lifecycle: AccessoryUsageLifecycle = .idle
    public var hasActiveTasks: Bool {
        connectionTask != nil || shutdownTask != nil
    }

    public init(
        client: any UsageStreamingClient,
        store: UsageStore,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    ) {
        self.client = client
        self.publishSnapshot = { store.snapshot = $0 }
        self.retryDelays = retryDelays.isEmpty ? [.seconds(30)] : retryDelays
    }

    public init(
        client: any UsageStreamingClient,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)],
        publishSnapshot: @escaping @MainActor (UsageSnapshot) -> Void
    ) {
        self.client = client
        self.publishSnapshot = publishSnapshot
        self.retryDelays = retryDelays.isEmpty ? [.seconds(30)] : retryDelays
    }

    public func start() async {
        guard lifecycle == .idle else { return }
        lifecycle = .starting
        connectionTask = Task { [weak self] in await self?.runConnectionLoop() }
        lifecycle = .running
    }

    public func shutdown() async throws {
        if lifecycle == .stopped { return }
        if let shutdownTask { return try await shutdownTask.value }
        lifecycle = .shuttingDown
        let task = Task { [weak self] () async throws -> Void in
            guard let self else { return }
            try await self.runShutdown()
        }
        shutdownTask = task
        do { try await task.value }
        catch {
            shutdownTask = nil
            lifecycle = .running
            publishSnapshot(.unavailable)
            throw error
        }
    }

    private func runConnectionLoop() async {
        let stream = await client.snapshots()
        var iterator = stream.makeAsyncIterator()
        if let initial = await iterator.next() { publishSnapshot(initial) }
        var attemptedInitialConnection = false
        var retryIndex = 0
        while !Task.isCancelled, lifecycle == .running {
            do {
                let snapshot: UsageSnapshot
                if attemptedInitialConnection {
                    snapshot = try await client.reconnect()
                } else {
                    snapshot = try await client.start()
                }
                attemptedInitialConnection = true
                guard !Task.isCancelled, lifecycle == .running else { return }
                retryIndex = 0
                publishSnapshot(snapshot)
                while !Task.isCancelled, lifecycle == .running, let update = await iterator.next() {
                    publishSnapshot(update)
                    if update == .unavailable { break }
                }
            } catch is CancellationError { return }
            catch {
                attemptedInitialConnection = true
                publishSnapshot(.unavailable)
            }
            guard !Task.isCancelled, lifecycle == .running else { return }
            let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
            retryIndex = min(retryIndex + 1, retryDelays.count - 1)
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    private func runShutdown() async throws {
        connectionTask?.cancel()
        do { try await client.close() }
        catch {
            await connectionTask?.value
            connectionTask = nil
            throw error
        }
        await connectionTask?.value
        connectionTask = nil
        shutdownTask = nil
        lifecycle = .stopped
    }
}
