import Foundation

public enum AppServerTransportTermination: Sendable, Equatable {
    case exited
    case readFailed
}

public protocol AppServerTransport: AnyObject, Sendable {
    func start(
        executable: URL,
        arguments: [String],
        onData: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (AppServerTransportTermination) -> Void,
        deadline: ContinuousClock.Instant
    ) async throws
    func write(_ data: Data, deadline: ContinuousClock.Instant) async throws
    func close(deadline: ContinuousClock.Instant) async throws
}

public enum AppServerClientError: Error, Sendable, Equatable {
    case closed
    case deadlineExceeded
    case transportFailure
    case protocolFailure
    case frameTooLarge
    case cleanupFailure
}

public protocol UsageStreamingClient: Sendable {
    func snapshots() async -> AsyncStream<UsageSnapshot>
    func start() async throws -> UsageSnapshot
    func reconnect() async throws -> UsageSnapshot
    func close() async throws
}

public final class ProcessTransport: AppServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var terminationHandler: (@Sendable (AppServerTransportTermination) -> Void)?
    private var operations: [UUID: @Sendable () -> Void] = [:]
    private var hasStarted = false

    public init() {}

    public func start(
        executable: URL,
        arguments: [String],
        onData: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (AppServerTransportTermination) -> Void,
        deadline: ContinuousClock.Instant
    ) async throws {
        let isFirstStart = lock.withLock { () -> Bool in
            guard !hasStarted else { return false }
            hasStarted = true
            return true
        }
        guard isFirstStart else { throw AppServerClientError.transportFailure }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.signalTermination(.exited) }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.signalTermination(.exited) }
            else { onData(data) }
        }
        lock.withLock {
            self.process = process
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            terminationHandler = onTermination
        }
        do {
            try await bounded(deadline: deadline, lateCompletion: {
                Task { try? await ChildProcessTerminator.stop(process) }
            }) { try process.run() }
        }
        catch {
            Task { try? await self.close(deadline: ContinuousClock().now.advanced(by: .seconds(1))) }
            throw (error as? AppServerClientError) ?? AppServerClientError.transportFailure
        }
    }

    public func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        let handle = lock.withLock { input }
        guard let handle else { throw AppServerClientError.transportFailure }
        do { try await bounded(deadline: deadline) { try handle.write(contentsOf: data) } }
        catch { throw (error as? AppServerClientError) ?? AppServerClientError.transportFailure }
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        let state = lock.withLock { () -> (Process?, FileHandle?, FileHandle?, [@Sendable () -> Void]) in
            let result = (process, input, output)
            input = nil
            output = nil
            terminationHandler = nil
            let cancellations = Array(operations.values)
            operations.removeAll()
            return (result.0, result.1, result.2, cancellations)
        }
        state.3.forEach { $0() }
        state.2?.readabilityHandler = nil
        try? state.1?.close()
        try? state.2?.close()
        if let process = state.0 {
            let remaining = max(.zero, ContinuousClock().now.duration(to: deadline))
            try await ChildProcessTerminator.stop(process, grace: min(.milliseconds(250), remaining / 2))
            lock.withLock { if self.process === process { self.process = nil } }
        }
    }

    private func bounded(
        deadline: ContinuousClock.Instant,
        lateCompletion: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () throws -> Void
    ) async throws {
        let id = UUID()
        let gate = OneShot<Void>()
        lock.withLock { operations[id] = { gate.resolve(.failure(AppServerClientError.closed)) } }
        defer { _ = lock.withLock { operations.removeValue(forKey: id) } }
        DispatchQueue.global(qos: .utility).async {
            do {
                try operation()
                if !gate.resolve(.success(())) { lateCompletion() }
            } catch {
                if !gate.resolve(.failure(AppServerClientError.transportFailure)) { lateCompletion() }
            }
        }
        Task.detached {
            try? await Task.sleep(until: deadline, clock: .continuous)
            gate.resolve(.failure(AppServerClientError.deadlineExceeded))
        }
        try await gate.value()
    }

    private func signalTermination(_ reason: AppServerTransportTermination) {
        let handler = lock.withLock { terminationHandler }
        handler?(reason)
    }
}

private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let resolution = lock.withLock { () -> (Bool, CheckedContinuation<Value, Error>?) in
            guard self.result == nil else { return (false, nil) }
            self.result = result
            let value = self.continuation
            self.continuation = nil
            return (true, value)
        }
        resolution.1?.resume(with: result)
        return resolution.0
    }
}

enum ChildProcessTerminator {
    static func stop(_ process: Process, grace: Duration = .milliseconds(250)) async throws {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        if await waitForExit(process, timeout: grace) { return }
        guard process.isRunning, process.processIdentifier == pid else { return }
        throw AppServerClientError.cleanupFailure
    }

    private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return !process.isRunning
    }
}

public actor AppServerClient: UsageStreamingClient {
    private enum Lifecycle {
        case idle
        case connecting(Task<UsageSnapshot, Error>)
        case connected
        case closing(Task<Void, Error>)
    }
    private let executable: URL
    private let transportFactory: @Sendable () -> any AppServerTransport
    private var transport: (any AppServerTransport)?
    private let deadline: Duration
    private let initialReadDeadline: Duration
    private let calibrationInterval: Duration
    private var decoder: JSONRPCLineDecoder
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var currentPayload: RateLimitPayload?
    private var currentSnapshot = UsageSnapshot.unavailable
    private var generation = 0
    private var closed = false
    private var connected = false
    private var transportStarted = false
    private var didObserveLiveUpdate = false
    private var lifecycle: Lifecycle = .idle
    private var closeBarrier: Task<Void, Error>?
    private var terminalCloseTask: Task<Void, Error>?
    private var calibrationTask: Task<Void, Never>?
    private var fullRefreshGeneration: Int?
    private var snapshotContinuations: [UUID: AsyncStream<UsageSnapshot>.Continuation] = [:]

    public init(
        executable: URL,
        transportFactory: @escaping @Sendable () -> any AppServerTransport = { ProcessTransport() },
        deadline: Duration = .seconds(10),
        initialReadDeadline: Duration = .seconds(30),
        calibrationInterval: Duration = .seconds(120),
        maximumFrameBytes: Int = 1_048_576
    ) {
        self.executable = executable
        self.transportFactory = transportFactory
        self.deadline = deadline
        self.initialReadDeadline = initialReadDeadline
        self.calibrationInterval = calibrationInterval
        self.decoder = JSONRPCLineDecoder(maximumFrameBytes: maximumFrameBytes)
    }

    public func snapshot() -> UsageSnapshot { currentSnapshot }
    public func observedLiveUpdate() -> Bool { didObserveLiveUpdate }
    func snapshotSubscriberCount() -> Int { snapshotContinuations.count }

    public func snapshots() -> AsyncStream<UsageSnapshot> {
        guard !closed else {
            return AsyncStream { continuation in
                continuation.yield(currentSnapshot)
                continuation.finish()
            }
        }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(currentSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    public func start() async throws -> UsageSnapshot {
        guard !closed else { throw AppServerClientError.closed }
        return try await startOrJoin()
    }

    public func reconnect() async throws -> UsageSnapshot {
        guard !closed else { throw AppServerClientError.closed }
        switch lifecycle {
        case let .connecting(task): _ = try? await task.value
        case let .closing(task): try await task.value
        case .idle, .connected: break
        }
        if case .connected = lifecycle {
            let connectionGeneration = generation
            let closeTask = Task {
                try await self.invalidate(
                    expectedGeneration: connectionGeneration,
                    closeTransport: true,
                    waitForClose: true
                )
            }
            lifecycle = .closing(closeTask)
            try await closeTask.value
            lifecycle = .idle
        } else if transportStarted {
            try await invalidate(expectedGeneration: generation, closeTransport: true, waitForClose: true)
        }
        return try await startOrJoin()
    }

    public func close() async throws {
        if let terminalCloseTask { return try await terminalCloseTask.value }
        guard !closed || transportStarted else { return }
        closed = true
        let connectionGeneration = generation
        let closeTask = Task {
            defer { self.finishSnapshotStreams() }
            try await self.invalidate(
                expectedGeneration: connectionGeneration,
                closeTransport: true,
                waitForClose: true
            )
        }
        terminalCloseTask = closeTask
        lifecycle = .closing(closeTask)
        do { try await closeTask.value }
        catch {
            terminalCloseTask = nil
            lifecycle = .idle
            throw error
        }
        lifecycle = .idle
    }

    private func startOrJoin() async throws -> UsageSnapshot {
        switch lifecycle {
        case .connected: return currentSnapshot
        case let .connecting(task): return try await task.value
        case let .closing(task):
            try await task.value
            lifecycle = .idle
            return try await startOrJoin()
        case .idle:
            let task = Task { try await self.connect() }
            lifecycle = .connecting(task)
            do {
                let snapshot = try await task.value
                lifecycle = .connected
                return snapshot
            } catch {
                lifecycle = .idle
                throw error
            }
        }
    }

    private func connect() async throws -> UsageSnapshot {
        if let closeBarrier {
            try await closeBarrier.value
            self.closeBarrier = nil
        }
        let candidate = transportFactory()
        transport = candidate
        generation += 1
        let connectionGeneration = generation
        let operationDeadline = ContinuousClock().now.advanced(by: initialReadDeadline)
        currentPayload = nil
        currentSnapshot = .unavailable
        decoder.reset()
        let deadlineTask = Task { [initialReadDeadline] in
            try? await Task.sleep(for: initialReadDeadline)
            guard !Task.isCancelled else { return }
            await self.expire(generation: connectionGeneration)
        }
        defer { deadlineTask.cancel() }
        do {
            try await startTransport(generation: connectionGeneration, deadline: operationDeadline)
            _ = try await request("initialize", params: ["clientInfo": .object([
                "name": .string("codex-quota"),
                "title": .string("Codex Quota"),
                "version": .string("0.1.1"),
            ])], generation: connectionGeneration)
            try await notify("initialized", params: [:], generation: connectionGeneration)
            let result = try await request("account/rateLimits/read", params: [:], generation: connectionGeneration)
            guard let limits = result.object?["rateLimits"], let payload = Self.parsePayload(limits) else { throw AppServerClientError.protocolFailure }
            guard connectionGeneration == generation, !closed else { throw AppServerClientError.closed }
            currentPayload = payload
            publish(UsageNormalizer.normalize(payload))
            connected = true
            startCalibrationLoop(generation: connectionGeneration)
            return currentSnapshot
        } catch {
            try? await invalidate(expectedGeneration: connectionGeneration, closeTransport: true)
            if let known = error as? AppServerClientError { throw known }
            throw AppServerClientError.transportFailure
        }
    }

    private func startTransport(generation: Int, deadline: ContinuousClock.Instant) async throws {
        guard let transport else { throw AppServerClientError.transportFailure }
        transportStarted = true
        do {
            try await transport.start(
                executable: executable,
                arguments: ["app-server", "--stdio"],
                onData: { [weak self] data in Task { await self?.receive(data, generation: generation) } },
                onTermination: { [weak self] reason in Task { await self?.terminated(reason, generation: generation) } },
                deadline: deadline
            )
            guard generation == self.generation, !closed else { throw AppServerClientError.closed }
        } catch { throw (error as? AppServerClientError) ?? AppServerClientError.transportFailure }
    }

    private func request(_ method: String, params: [String: JSONValue], generation: Int) async throws -> JSONValue {
        guard generation == self.generation, !closed else { throw AppServerClientError.closed }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await self.write(.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)]), generation: generation) }
                catch { self.failRequest(id: id, error: error) }
            }
        }
    }

    private func notify(_ method: String, params: [String: JSONValue], generation: Int) async throws {
        try await write(.object(["method": .string(method), "params": .object(params)]), generation: generation)
    }

    private func write(_ value: JSONValue, generation: Int) async throws {
        guard generation == self.generation, !closed else { throw AppServerClientError.closed }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        let requestDeadline = ContinuousClock().now.advanced(by: deadline)
        guard let transport else { throw AppServerClientError.transportFailure }
        do { try await transport.write(data, deadline: requestDeadline) }
        catch { throw (error as? AppServerClientError) ?? AppServerClientError.transportFailure }
    }

    private func failRequest(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receive(_ data: Data, generation: Int) async {
        guard generation == self.generation, !closed else { return }
        let lines: [Data]
        do { lines = try decoder.append(data) }
        catch {
            try? await invalidate(expectedGeneration: generation, closeTransport: true, failure: .frameTooLarge)
            return
        }
        for line in lines {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: line), let object = message.object else { continue }
            if object["id"] != nil {
                guard let id = object["id"]?.int else {
                    try? await invalidate(expectedGeneration: generation, closeTransport: true)
                    return
                }
                guard let continuation = pending.removeValue(forKey: id) else { continue }
                if object["error"] != nil { continuation.resume(throwing: AppServerClientError.protocolFailure) }
                else { continuation.resume(returning: object["result"] ?? .object([:])) }
                continue
            }
            guard connected, object["method"]?.string == "account/rateLimits/updated",
                  let limits = object["params"]?.object?["rateLimits"], let currentPayload else { continue }
            guard let patch = Self.parsePatch(limits) else {
                connected = false
                Task { await self.refresh(generation: generation) }
                continue
            }
            switch UsageNormalizer.merge(currentPayload, patch) {
            case let .merged(payload):
                self.currentPayload = payload
                publish(UsageNormalizer.normalize(payload))
                didObserveLiveUpdate = true
            case .requiresFullRefresh:
                connected = false
                Task { await self.refresh(generation: generation) }
            }
        }
    }

    private func refresh(generation: Int) async {
        guard generation == self.generation, !closed, fullRefreshGeneration == nil else { return }
        fullRefreshGeneration = generation
        defer {
            if fullRefreshGeneration == generation { fullRefreshGeneration = nil }
        }
        let deadlineTask = Task { [deadline] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            await self.expire(generation: generation)
        }
        defer { deadlineTask.cancel() }
        do {
            let result = try await request("account/rateLimits/read", params: [:], generation: generation)
            guard generation == self.generation, !closed, let limits = result.object?["rateLimits"], let payload = Self.parsePayload(limits) else { return }
            currentPayload = payload
            publish(UsageNormalizer.normalize(payload))
            connected = true
        } catch {
            try? await invalidate(expectedGeneration: generation, closeTransport: true)
        }
    }

    private func terminated(_ reason: AppServerTransportTermination, generation: Int) async {
        guard generation == self.generation, !closed else { return }
        try? await invalidate(expectedGeneration: generation, closeTransport: true)
    }

    private func expire(generation: Int) async {
        try? await invalidate(
            expectedGeneration: generation,
            closeTransport: true,
            failure: .deadlineExceeded
        )
    }

    private func invalidate(
        expectedGeneration: Int,
        closeTransport: Bool,
        waitForClose: Bool = false,
        failure: AppServerClientError = .transportFailure
    ) async throws {
        guard expectedGeneration == generation else { return }
        stopCalibrationLoop()
        generation += 1
        connected = false
        fullRefreshGeneration = nil
        currentPayload = nil
        publish(.unavailable)
        decoder.reset()
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: failure) }
        if closeTransport, transportStarted {
            transportStarted = false
            let closingTransport = transport
            transport = nil
            let closeDeadline = ContinuousClock().now.advanced(by: .seconds(1))
            let barrier = Task { if let closingTransport { try await closingTransport.close(deadline: closeDeadline) } }
            closeBarrier = barrier
            if waitForClose {
                do {
                    try await barrier.value
                    closeBarrier = nil
                } catch {
                    transport = closingTransport
                    transportStarted = closingTransport != nil
                    closeBarrier = nil
                    throw error
                }
            }
        }
    }

    private func publish(_ snapshot: UsageSnapshot) {
        guard currentSnapshot != snapshot else { return }
        currentSnapshot = snapshot
        snapshotContinuations.values.forEach { $0.yield(snapshot) }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func finishSnapshotStreams() {
        snapshotContinuations.values.forEach { $0.finish() }
        snapshotContinuations.removeAll()
    }

    private func startCalibrationLoop(generation: Int) {
        stopCalibrationLoop()
        let interval = calibrationInterval
        calibrationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.runPeriodicCalibration(generation: generation)
            }
        }
    }

    private func stopCalibrationLoop() {
        calibrationTask?.cancel()
        calibrationTask = nil
    }

    private func runPeriodicCalibration(generation: Int) async {
        guard generation == self.generation, connected, !closed else { return }
        await refresh(generation: generation)
    }

    private static func parsePayload(_ value: JSONValue) -> RateLimitPayload? {
        guard let object = value.object else { return nil }
        return .init(primary: parseWindow(object["primary"]), secondary: parseWindow(object["secondary"]), additional: [])
    }

    private static func parseWindow(_ value: JSONValue?) -> RateLimitPayload.Window? {
        guard let object = value?.object else { return nil }
        return .init(usedPercent: object["usedPercent"]?.double, windowDurationMins: object["windowDurationMins"]?.int, resetsAt: object["resetsAt"]?.int64)
    }

    private static func parsePatch(_ value: JSONValue) -> RateLimitPatch? {
        guard let object = value.object else { return nil }
        guard let primary = windowPatch("primary", in: object), let secondary = windowPatch("secondary", in: object) else { return nil }
        return .init(primary: primary, secondary: secondary)
    }

    private static func windowPatch(_ key: String, in object: [String: JSONValue]) -> FieldPatch<RateLimitPatch.Window>? {
        guard let value = object[key] else { return .some(.missing) }
        if value.isNull { return .some(.null) }
        guard let fields = value.object,
              let usedPercent = fieldPatch("usedPercent", in: fields, transform: { $0.finiteDouble }),
              let duration = fieldPatch("windowDurationMins", in: fields, transform: { $0.int }),
              let resetsAt = fieldPatch("resetsAt", in: fields, transform: { $0.int64 }) else { return nil }
        return .value(.init(
            usedPercent: usedPercent,
            windowDurationMins: duration,
            resetsAt: resetsAt
        ))
    }

    private static func fieldPatch<T: Sendable & Equatable>(_ key: String, in object: [String: JSONValue], transform: (JSONValue) -> T?) -> FieldPatch<T>? {
        guard let value = object[key] else { return .some(.missing) }
        if value.isNull { return .some(.null) }
        guard let transformed = transform(value) else { return nil }
        return .value(transformed)
    }
}

private indirect enum JSONValue: Codable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { throw AppServerClientError.protocolFailure }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: JSONValue]? { if case let .object(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var double: Double? { if case let .number(value) = self { value } else { nil } }
    var finiteDouble: Double? { double.flatMap { $0.isFinite ? $0 : nil } }
    var int: Int? { finiteDouble.flatMap { $0.rounded() == $0 && $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : nil } }
    var int64: Int64? { finiteDouble.flatMap { $0.rounded() == $0 && $0 >= Double(Int64.min) && $0 < Double(Int64.max) ? Int64($0) : nil } }
    var isNull: Bool { if case .null = self { true } else { false } }
}
