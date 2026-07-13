import Foundation
@testable import CodexUsageCore

enum Fixtures {
    static let snapshot = RateLimitPayload(
        primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 1_900_000_000),
        secondary: .init(usedPercent: 34, windowDurationMins: 10_080, resetsAt: 1_900_500_000)
    )

    static func response(id: Int, rateLimits: String) -> Data {
        Data("{\"id\":\(id),\"result\":{\"rateLimits\":\(rateLimits)}}\n".utf8)
    }

    static let snapshotJSON = """
    {"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1900500000}}
    """
}

actor FakeAppServerTransport: AppServerTransport {
    enum Failure: Error { case spawn, write }

    private(set) var starts: [(URL, [String])] = []
    private(set) var messages: [[String: AnySendable]] = []
    private(set) var closeCount = 0
    var spawnFailure = false
    var writeFailureAt: Int?
    var hangsOnStart = false
    var hangsOnWrite = false
    var closeDelay: Duration = .zero
    var closeFailures = 0
    private var hasStarted = false
    private var dataHandler: (@Sendable (Data) -> Void)?
    private var lastDataHandler: (@Sendable (Data) -> Void)?
    private var terminationHandler: (@Sendable (AppServerTransportTermination) -> Void)?

    func start(
        executable: URL,
        arguments: [String],
        onData: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (AppServerTransportTermination) -> Void,
        deadline: ContinuousClock.Instant
    ) async throws {
        guard !hasStarted else { throw AppServerClientError.transportFailure }
        hasStarted = true
        if hangsOnStart {
            try await Task.sleep(until: deadline, clock: .continuous)
            throw AppServerClientError.deadlineExceeded
        }
        if spawnFailure { throw Failure.spawn }
        starts.append((executable, arguments))
        dataHandler = onData
        lastDataHandler = onData
        terminationHandler = onTermination
    }

    func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        if hangsOnWrite {
            try await Task.sleep(until: deadline, clock: .continuous)
            throw AppServerClientError.deadlineExceeded
        }
        if writeFailureAt == messages.count { throw Failure.write }
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        messages.append(object.mapValues(AnySendable.init))
    }

    func close(deadline: ContinuousClock.Instant) async throws {
        if closeDelay > .zero { try? await Task.sleep(for: closeDelay) }
        closeCount += 1
        if closeFailures > 0 { closeFailures -= 1; throw AppServerClientError.cleanupFailure }
        dataHandler = nil
        terminationHandler = nil
    }

    func emit(_ data: Data) { dataHandler?(data) }
    func emitLate(_ data: Data) { lastDataHandler?(data) }
    func disconnect() { terminationHandler?(.exited) }
    func failRead() { terminationHandler?(.readFailed) }

    func methods() -> [String] { messages.compactMap { $0["method"]?.value as? String } }
    func requestIDs() -> [Int] { messages.compactMap { $0["id"]?.value as? Int } }
    func handlersInstalled() -> Bool { dataHandler != nil || terminationHandler != nil }
}

struct AnySendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
