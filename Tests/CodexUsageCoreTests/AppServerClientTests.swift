import Foundation
import Darwin
import Testing
@testable import CodexUsageCore

@Suite("AppServerClient")
struct AppServerClientTests {
    let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")

    @Test("JSON 行解码器限制无换行缓冲、完整帧并允许多条合法帧")
    func decoderFrameLimits() throws {
        var decoder = JSONRPCLineDecoder(maximumFrameBytes: 4)
        #expect(try decoder.append(Data("1234".utf8)).isEmpty)
        #expect(throws: AppServerClientError.frameTooLarge) { try decoder.append(Data("5".utf8)) }

        decoder.reset()
        #expect(try decoder.append(Data("1234\n".utf8)) == [Data("1234".utf8)])
        #expect(throws: AppServerClientError.frameTooLarge) { try decoder.append(Data("12345\n".utf8)) }

        decoder.reset()
        let many = try decoder.append(Data("1234\n1234\n1234\n".utf8))
        #expect(many.count == 3)
    }

    @Test("超限 JSON 帧使连接 fail closed 并关闭 transport")
    func oversizedFrameClosesTransport() async throws {
        let transport = FakeAppServerTransport()
        let client = AppServerClient(
            executable: executable,
            transportFactory: { transport },
            deadline: .seconds(1),
            maximumFrameBytes: 8
        )
        let started = Task { try await client.start() }
        try await eventually { await transport.handlersInstalled() }
        await transport.emit(Data(repeating: 0x41, count: 9))
        await #expect(throws: AppServerClientError.frameTooLarge) { try await started.value }
        try await eventually { await transport.closeCount == 1 }
        #expect(await client.snapshot() == .unavailable)
    }

    @Test("snapshot stream 发布完整值、合并更新、断连不可用并在 close 结束")
    func snapshotStreamLifecycle() async throws {
        let (client, transport) = try await connectedClient()
        let stream = await client.snapshots()
        #expect(await client.snapshotSubscriberCount() == 1)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.fiveHour.remainingPercent == 80)

        await transport.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"usedPercent\":27}}}}\n".utf8))
        #expect(await iterator.next()?.fiveHour.remainingPercent == 73)
        await transport.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":null}}}}\n".utf8))
        try await eventually { await transport.methods().filter { $0 == "account/rateLimits/read" }.count == 2 }
        let refreshID = try #require(await transport.requestIDs().last)
        await transport.emit(Fixtures.response(id: refreshID, rateLimits: Fixtures.snapshotJSON))
        #expect(await iterator.next()?.fiveHour.remainingPercent == 80)
        await transport.disconnect()
        #expect(await iterator.next() == .unavailable)
        try await client.close()
        #expect(await iterator.next() == nil)
        #expect(await client.snapshotSubscriberCount() == 0)
    }

    @Test("terminal close 后新 snapshot stream 立即结束且不注册 subscriber")
    func subscribeAfterCloseEndsImmediately() async throws {
        let (client, _) = try await connectedClient()
        try await client.close()

        let values = await collectUntilFinished(await client.snapshots(), timeout: .milliseconds(50))
        #expect(values == [.unavailable])
        #expect(await client.snapshotSubscriberCount() == 0)
    }

    @Test("握手严格按 initialize、initialized、read 排序")
    func handshakeOrder() async throws {
        let transport = FakeAppServerTransport()
        let client = AppServerClient(executable: executable, transportFactory: { transport }, deadline: .seconds(1))
        let started = Task { try await client.start() }
        try await eventually { await transport.methods() == ["initialize"] }
        let initializeID = try #require(await transport.requestIDs().first)
        await transport.emit(Fixtures.response(id: initializeID, rateLimits: "{}"))
        try await eventually { await transport.methods().count == 3 }
        #expect(await transport.methods() == ["initialize", "initialized", "account/rateLimits/read"])
        let readID = try #require(await transport.requestIDs().last)
        await transport.emit(Fixtures.response(id: readID, rateLimits: Fixtures.snapshotJSON))
        #expect(try await started.value == UsageNormalizer.normalize(Fixtures.snapshot))
        let starts = await transport.starts
        #expect(starts.first?.1 == ["app-server", "--stdio"])
        try await client.close()
    }

    @Test("JSON 行仅在 newline 后解码")
    func fragmentedLine() async throws {
        let transport = FakeAppServerTransport()
        let client = AppServerClient(executable: executable, transportFactory: { transport }, deadline: .seconds(1))
        let started = Task { try await client.start() }
        try await eventually { await transport.requestIDs().count == 1 }
        let id = try #require(await transport.requestIDs().first)
        let response = Fixtures.response(id: id, rateLimits: "{}")
        await transport.emit(response.dropLast())
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.methods() == ["initialize"])
        await transport.emit(Data("\n".utf8))
        try await eventually { await transport.methods().count == 3 }
        let readID = try #require(await transport.requestIDs().last)
        await transport.emit(Fixtures.response(id: readID, rateLimits: Fixtures.snapshotJSON))
        _ = try await started.value
        try await client.close()
    }

    @Test("稀疏通知安全合并；身份不明时重新 read")
    func sparseUpdateAndRefresh() async throws {
        let (client, transport) = try await connectedClient()
        await transport.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"usedPercent\":27}}}}\n".utf8))
        try await eventually { await client.snapshot().fiveHour.remainingPercent == 73 }
        #expect(await client.snapshot().fiveHour.resetsAt == 1_900_000_000)

        await transport.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":null}}}}\n".utf8))
        try await eventually { await transport.methods().filter { $0 == "account/rateLimits/read" }.count == 2 }
        let refreshID = try #require(await transport.requestIDs().last)
        await transport.emit(Fixtures.response(id: refreshID, rateLimits: Fixtures.snapshotJSON))
        try await eventually { await client.snapshot().fiveHour.remainingPercent == 80 }
        try await client.close()
    }

    @Test("整体 deadline、spawn/write/read failure 都不可用并清理")
    func boundedFailures() async throws {
        let timeoutTransport = FakeAppServerTransport()
        let timeoutClient = AppServerClient(
            executable: executable,
            transportFactory: { timeoutTransport },
            deadline: .milliseconds(30),
            initialReadDeadline: .milliseconds(30)
        )
        await #expect(throws: AppServerClientError.self) { try await timeoutClient.start() }
        #expect(await timeoutClient.snapshot() == .unavailable)
        #expect(await timeoutTransport.closeCount == 1)

        let spawnTransport = FakeAppServerTransport()
        await spawnTransport.setSpawnFailure()
        let spawnClient = AppServerClient(executable: executable, transportFactory: { spawnTransport }, deadline: .seconds(1))
        await #expect(throws: AppServerClientError.self) { try await spawnClient.start() }

        let writeTransport = FakeAppServerTransport()
        await writeTransport.setWriteFailure(at: 0)
        let writeClient = AppServerClient(executable: executable, transportFactory: { writeTransport }, deadline: .seconds(1))
        await #expect(throws: AppServerClientError.self) { try await writeClient.start() }

        let readTransport = FakeAppServerTransport()
        let readClient = AppServerClient(executable: executable, transportFactory: { readTransport }, deadline: .seconds(1))
        let task = Task { try await readClient.start() }
        try await eventually { await readTransport.handlersInstalled() }
        await readTransport.failRead()
        await #expect(throws: AppServerClientError.self) { try await task.value }
        #expect(await readClient.snapshot() == .unavailable)
    }

    @Test("start/write 挂起仍遵守整体 deadline，迟到完成不复活")
    func hangingOperationsRespectDeadline() async throws {
        let startTransport = FakeAppServerTransport()
        await startTransport.setHangsOnStart()
        let startClient = AppServerClient(
            executable: executable,
            transportFactory: { startTransport },
            deadline: .milliseconds(30),
            initialReadDeadline: .milliseconds(30)
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        await #expect(throws: AppServerClientError.self) { try await startClient.start() }
        #expect(startedAt.duration(to: clock.now) < .milliseconds(250))
        try await eventually { await startTransport.closeCount >= 1 }
        #expect(await startClient.snapshot() == .unavailable)

        let writeTransport = FakeAppServerTransport()
        await writeTransport.setHangsOnWrite()
        let writeClient = AppServerClient(
            executable: executable,
            transportFactory: { writeTransport },
            deadline: .milliseconds(30),
            initialReadDeadline: .milliseconds(30)
        )
        await #expect(throws: AppServerClientError.self) { try await writeClient.start() }
        try await eventually { await writeTransport.closeCount >= 1 }
        await writeTransport.emitLate(Fixtures.response(id: 1, rateLimits: Fixtures.snapshotJSON))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await writeClient.snapshot() == .unavailable)
    }

    @Test("首个额度响应可超过常规操作预算但不能超过冷启动预算")
    func slowInitialReadUsesDedicatedColdStartDeadline() async throws {
        let transport = FakeAppServerTransport()
        let client = AppServerClient(
            executable: executable,
            transportFactory: { transport },
            deadline: .milliseconds(100),
            initialReadDeadline: .milliseconds(500)
        )

        let started = Task { try await client.start() }
        try await eventually { await transport.requestIDs().count == 1 }
        let initializeID = try #require(await transport.requestIDs().first)
        await transport.emit(Fixtures.response(id: initializeID, rateLimits: "{}"))
        try await eventually { await transport.requestIDs().count == 2 }

        try await Task.sleep(for: .milliseconds(150))
        let readID = try #require(await transport.requestIDs().last)
        await transport.emit(Fixtures.response(id: readID, rateLimits: Fixtures.snapshotJSON))

        #expect(try await started.value == UsageNormalizer.normalize(Fixtures.snapshot))
        #expect(await transport.closeCount == 0)
        try await client.close()
    }

    @Test("存活连接超过首次握手 timeout 后仍可按新 deadline refresh")
    func refreshUsesFreshRequestDeadline() async throws {
        let transport = FakeAppServerTransport()
        let client = AppServerClient(executable: executable, transportFactory: { transport }, deadline: .milliseconds(30))
        let started = Task { try await client.start() }
        try await eventually { await transport.requestIDs().count == 1 }
        await transport.emit(Fixtures.response(id: await transport.requestIDs()[0], rateLimits: "{}"))
        try await eventually { await transport.requestIDs().count == 2 }
        await transport.emit(Fixtures.response(id: await transport.requestIDs()[1], rateLimits: Fixtures.snapshotJSON))
        _ = try await started.value
        try await Task.sleep(for: .milliseconds(50))

        await transport.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":null}}}}\n".utf8))
        try await eventually { await transport.requestIDs().count == 3 }
        await transport.emit(Fixtures.response(id: await transport.requestIDs()[2], rateLimits: Fixtures.snapshotJSON))
        try await eventually { await client.snapshot().fiveHour.remainingPercent == 80 }
        try await client.close()
    }

    @Test("无推送时按 fixed-delay 周期读取完整快照")
    func periodicCalibrationRefreshesWithoutPush() async throws {
        let (client, transport) = try await connectedClient(calibrationInterval: .milliseconds(40))
        try await eventually {
            await transport.methods().filter { $0 == "account/rateLimits/read" }.count == 2
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await transport.methods().filter { $0 == "account/rateLimits/read" }.count == 2)
        let calibrationID = try #require(await transport.requestIDs().last)
        let updated = """
        {"primary":{"usedPercent":39,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":39,"windowDurationMins":10080,"resetsAt":1900500000}}
        """
        await transport.emit(Fixtures.response(id: calibrationID, rateLimits: updated))
        try await eventually { await client.snapshot().weekly.remainingPercent == 61 }
        try await Task.sleep(for: .milliseconds(15))
        #expect(await transport.methods().filter { $0 == "account/rateLimits/read" }.count == 2)
        try await eventually {
            await transport.methods().filter { $0 == "account/rateLimits/read" }.count == 3
        }
        try await client.close()
    }

    @Test("周期读取与推送触发刷新在两个方向均保持单飞")
    func fullRefreshIsSingleFlightInBothDirections() async throws {
        let (periodicFirst, periodicTransport) = try await connectedClient(calibrationInterval: .milliseconds(20))
        try await eventually {
            await periodicTransport.methods().filter { $0 == "account/rateLimits/read" }.count == 2
        }
        await periodicTransport.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":null}}}}\n".utf8))
        try await Task.sleep(for: .milliseconds(10))
        #expect(await periodicTransport.methods().filter { $0 == "account/rateLimits/read" }.count == 2)
        let periodicID = try #require(await periodicTransport.requestIDs().last)
        await periodicTransport.emit(Fixtures.response(id: periodicID, rateLimits: Fixtures.snapshotJSON))
        try await periodicFirst.close()

        let (pushFirst, pushTransport) = try await connectedClient(calibrationInterval: .milliseconds(20))
        await pushTransport.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":null}}}}\n".utf8))
        try await eventually {
            await pushTransport.methods().filter { $0 == "account/rateLimits/read" }.count == 2
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await pushTransport.methods().filter { $0 == "account/rateLimits/read" }.count == 2)
        let pushID = try #require(await pushTransport.requestIDs().last)
        await pushTransport.emit(Fixtures.response(id: pushID, rateLimits: Fixtures.snapshotJSON))
        try await pushFirst.close()
    }

    @Test("旧周期读取失败与迟到响应不能破坏重连后的新 generation")
    func staleCalibrationCannotInvalidateReconnectedGeneration() async throws {
        let first = FakeAppServerTransport()
        let second = FakeAppServerTransport()
        let transports = TransportSequence([first, second])
        let client = AppServerClient(
            executable: executable,
            transportFactory: { transports.next() },
            deadline: .seconds(1),
            calibrationInterval: .milliseconds(30)
        )
        let started = Task { try await client.start() }
        try await completeHandshake(transport: first)
        _ = try await started.value
        try await eventually {
            await first.methods().filter { $0 == "account/rateLimits/read" }.count == 2
        }
        let staleReadID = try #require(await first.requestIDs().last)
        await first.disconnect()
        try await eventually { await client.snapshot() == .unavailable }

        let reconnect = Task { try await client.reconnect() }
        try await completeHandshake(transport: second)
        _ = try await reconnect.value
        #expect(await client.snapshot().weekly.remainingPercent == 66)
        let stale = """
        {"primary":{"usedPercent":39,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":39,"windowDurationMins":10080,"resetsAt":1900500000}}
        """
        await first.emitLate(Fixtures.response(id: staleReadID, rateLimits: stale))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await client.snapshot().weekly.remainingPercent == 66)
        #expect(await second.closeCount == 0)
        try await eventually {
            await second.methods().filter { $0 == "account/rateLimits/read" }.count == 2
        }
        let newCalibrationID = try #require(await second.requestIDs().last)
        await second.emit(Fixtures.response(id: newCalibrationID, rateLimits: Fixtures.snapshotJSON))
        try await eventually {
            await second.methods().filter { $0 == "account/rateLimits/read" }.count == 3
        }
        #expect(await first.methods().filter { $0 == "account/rateLimits/read" }.count == 2)
        try await client.close()
    }

    @Test("周期读取在途时关闭会拒绝迟到响应并释放客户端")
    func closeDuringCalibrationRejectsLateResponseAndReleasesClient() async throws {
        let transport = FakeAppServerTransport()
        let box: WeakClientBox
        do {
            let client = AppServerClient(
                executable: executable,
                transportFactory: { transport },
                deadline: .seconds(1),
                calibrationInterval: .milliseconds(20)
            )
            box = WeakClientBox(client)
            let started = Task { try await client.start() }
            try await completeHandshake(transport: transport)
            _ = try await started.value
            try await eventually {
                await transport.methods().filter { $0 == "account/rateLimits/read" }.count == 2
            }
            let lateID = try #require(await transport.requestIDs().last)
            try await client.close()
            await transport.emitLate(Fixtures.response(id: lateID, rateLimits: Fixtures.snapshotJSON))
            #expect(await client.snapshot() == .unavailable)
        }
        try await eventually { box.value == nil }
    }

    @Test("校准任务休眠期间不会强持有客户端")
    func sleepingCalibrationDoesNotRetainClient() async throws {
        let transport = FakeAppServerTransport()
        let box: WeakClientBox
        do {
            let client = AppServerClient(
                executable: executable,
                transportFactory: { transport },
                deadline: .seconds(1),
                calibrationInterval: .seconds(30)
            )
            box = WeakClientBox(client)
            let started = Task { try await client.start() }
            try await completeHandshake(transport: transport)
            _ = try await started.value
        }
        try await eventually { box.value == nil }
    }

    @Test("child terminator 不强杀失去可确认所有权的目标，也不影响无关进程")
    func childTerminatorDoesNotKillUnrelatedProcess() async throws {
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/bin/sh")
        target.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try target.run()
        try unrelated.run()
        defer {
            if target.isRunning { target.interrupt() }
            if unrelated.isRunning { unrelated.terminate() }
        }
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: AppServerClientError.cleanupFailure) {
            try await ChildProcessTerminator.stop(target, grace: .milliseconds(100))
        }
        #expect(target.isRunning)
        #expect(unrelated.isRunning)
    }

    @Test("close 幂等且迟到数据不复活，listener/child 清理")
    func closeIgnoresLateData() async throws {
        let (client, transport) = try await connectedClient()
        try await client.close()
        try await client.close()
        #expect(await transport.closeCount == 1)
        #expect(await transport.handlersInstalled() == false)
        await transport.emitLate(Data("{\"id\":999,\"error\":{\"message\":\"late\"}}\n{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"usedPercent\":1}}}}\n".utf8))
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await client.snapshot() == .unavailable)
    }

    @Test("断连立即 unavailable；重连完成 full snapshot 前拒绝迟到 update")
    func disconnectAndReconnect() async throws {
        let first = FakeAppServerTransport()
        let second = FakeAppServerTransport()
        let factory = TransportSequence([first, second])
        let client = AppServerClient(executable: executable, transportFactory: { factory.next() }, deadline: .seconds(1))
        let initial = Task { try await client.start() }
        try await eventually { await first.requestIDs().count == 1 }
        await first.emit(Fixtures.response(id: await first.requestIDs()[0], rateLimits: "{}"))
        try await eventually { await first.requestIDs().count == 2 }
        await first.emit(Fixtures.response(id: await first.requestIDs()[1], rateLimits: Fixtures.snapshotJSON))
        _ = try await initial.value
        await first.disconnect()
        try await eventually { await client.snapshot() == .unavailable }
        let reconnect = Task { try await client.reconnect() }
        try await eventually { await second.methods() == ["initialize"] }
        let initializeID = try #require(await second.requestIDs().last)
        await second.emit(Fixtures.response(id: initializeID, rateLimits: "{}"))
        try await eventually { await second.methods().contains("account/rateLimits/read") }
        await first.emitLate(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"usedPercent\":1}}}}\n".utf8))
        #expect(await client.snapshot() == .unavailable)
        let readID = try #require(await second.requestIDs().last)
        await second.emit(Fixtures.response(id: readID, rateLimits: Fixtures.snapshotJSON))
        #expect(try await reconnect.value.fiveHour.remainingPercent == 80)
        try await client.close()
    }

    @Test("并发 start 共享连接；旧 close 完成前 reconnect 不启动新 transport")
    func sharedStartAndCloseBarrier() async throws {
        let first = FakeAppServerTransport()
        await first.setCloseDelay(.milliseconds(80))
        let second = FakeAppServerTransport()
        let factory = TransportSequence([first, second])
        let client = AppServerClient(executable: executable, transportFactory: { factory.next() }, deadline: .seconds(1))
        let a = Task { try await client.start() }
        let b = Task { try await client.start() }
        try await eventually { await first.requestIDs().count == 1 }
        #expect(await first.starts.count == 1)
        await first.emit(Fixtures.response(id: await first.requestIDs()[0], rateLimits: "{}"))
        try await eventually { await first.requestIDs().count == 2 }
        await first.emit(Fixtures.response(id: await first.requestIDs()[1], rateLimits: Fixtures.snapshotJSON))
        let firstResult = try await a.value
        let secondResult = try await b.value
        #expect(firstResult == secondResult)

        await first.disconnect()
        let reconnect = Task { try await client.reconnect() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await second.starts.isEmpty)
        try await eventually(timeout: .seconds(1)) { await second.starts.count == 1 }
        try await eventually { await second.requestIDs().count == 1 }
        await second.emit(Fixtures.response(id: await second.requestIDs()[0], rateLimits: "{}"))
        try await eventually { await second.requestIDs().count == 2 }
        await second.emit(Fixtures.response(id: await second.requestIDs()[1], rateLimits: Fixtures.snapshotJSON))
        _ = try await reconnect.value
        try await client.close()
    }

    @Test("并发 close 共享同一 barrier；terminal close 后不能 start")
    func concurrentCloseJoinsBarrier() async throws {
        let (client, transport) = try await connectedClient()
        await transport.setCloseDelay(.milliseconds(80))
        let completions = CompletionCounter()
        let first = Task { try await client.close(); await completions.mark() }
        let second = Task { try await client.close(); await completions.mark() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completions.value == 0)
        try await first.value
        try await second.value
        #expect(await completions.value == 2)
        #expect(await transport.closeCount == 1)
        await #expect(throws: AppServerClientError.closed) { try await client.start() }
    }

    @Test("cleanup failure 传播且 terminal close 可重试")
    func closeCleanupFailureCanRetry() async throws {
        let (client, transport) = try await connectedClient()
        await transport.setCloseFailures(1)
        await #expect(throws: AppServerClientError.cleanupFailure) { try await client.close() }
        #expect(await transport.closeCount == 1)
        try await client.close()
        #expect(await transport.closeCount == 2)
    }

    @Test("factory 返回同一强持有 transport 时由实例自身拒绝二次 start")
    func reusedTransportRejectsSecondStart() async throws {
        let (client, _) = try await connectedClient()
        await #expect(throws: AppServerClientError.transportFailure) { try await client.reconnect() }
    }

    @Test("fresh factory 可连续重连且不依赖对象地址历史")
    func freshFactorySupportsRepeatedReconnects() async throws {
        let transports = [FakeAppServerTransport(), FakeAppServerTransport(), FakeAppServerTransport()]
        let factory = TransportSequence(transports)
        let client = AppServerClient(executable: executable, transportFactory: { factory.next() }, deadline: .seconds(1))
        for (index, transport) in transports.enumerated() {
            let operation = Task { index == 0 ? try await client.start() : try await client.reconnect() }
            try await eventually { await transport.requestIDs().count == 1 }
            await transport.emit(Fixtures.response(id: await transport.requestIDs()[0], rateLimits: "{}"))
            try await eventually { await transport.requestIDs().count == 2 }
            await transport.emit(Fixtures.response(id: await transport.requestIDs()[1], rateLimits: Fixtures.snapshotJSON))
            #expect(try await operation.value.fiveHour.remainingPercent == 80)
        }
        try await client.close()
    }

    @Test("locator 仅接受固定 ChatGPT.app 身份与 app-server capability")
    func executableLocatorGate() async throws {
        let rejectedCounter = CallCounter()
        let valid = FakeInstallationInspector(bundleID: "com.openai.codex", executable: true, capability: true)
        #expect(try await CodexExecutableLocator(inspector: valid).locate() == CodexExecutableLocator.executableURL)

        await #expect(throws: CodexExecutableLocatorError.invalidBundleIdentity) {
            try await CodexExecutableLocator(inspector: FakeInstallationInspector(bundleID: "example.invalid", executable: true, capability: true)).locate()
        }
        await #expect(throws: CodexExecutableLocatorError.unsupportedInstallation) {
            try await CodexExecutableLocator(inspector: FakeInstallationInspector(bundleID: "com.openai.codex", executable: false, capability: true)).locate()
        }
        await #expect(throws: CodexExecutableLocatorError.missingAppServerCapability) {
            try await CodexExecutableLocator(inspector: FakeInstallationInspector(bundleID: "com.openai.codex", executable: true, capability: false)).locate()
        }
        await #expect(throws: CodexExecutableLocatorError.invalidBundleIdentity) {
            try await CodexExecutableLocator(inspector: FakeInstallationInspector(bundleID: "com.openai.codex", executable: true, capability: true, canonical: false, capabilityCounter: rejectedCounter)).locate()
        }
        await #expect(throws: CodexExecutableLocatorError.invalidBundleIdentity) {
            try await CodexExecutableLocator(inspector: FakeInstallationInspector(bundleID: "com.openai.codex", executable: true, capability: true, signature: false, capabilityCounter: rejectedCounter)).locate()
        }
        #expect(rejectedCounter.value == 0)
    }

    @Test("系统 capability probe 取消时及时终止子进程")
    func capabilityProbeRespondsToCancellation() async throws {
        let inspector = SystemCodexInstallationInspector()
        let task = Task { await inspector.supportsAppServer(executableURL: URL(fileURLWithPath: "/usr/bin/yes")) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        let result = await task.value
        #expect(result == false)
    }

    @Test("capability probe 清理在调用任务已取消时仍确认 PID 退出")
    func capabilityProbeCleanupIsNonCancellable() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        let cleanup = Task { await SystemCodexInstallationInspector.stopCapabilityProbe(process) }
        cleanup.cancel()

        #expect(await cleanup.value)
        #expect(process.isRunning == false)
        #expect(Darwin.kill(pid, 0) == -1)
    }

    @Test("非法数字 ID fail closed；非法 patch 字段触发 full refresh")
    func invalidNumericProtocolValues() async throws {
        let transport = FakeAppServerTransport()
        let client = AppServerClient(executable: executable, transportFactory: { transport }, deadline: .seconds(1))
        let started = Task { try await client.start() }
        try await eventually { await transport.requestIDs().count == 1 }
        await transport.emit(Data("{\"id\":1.5,\"result\":{}}\n".utf8))
        await #expect(throws: AppServerClientError.self) { try await started.value }
        #expect(await client.snapshot() == .unavailable)

        for (field, invalid) in [("usedPercent", "\"bad\""), ("windowDurationMins", "1.5"), ("resetsAt", "1e300")] {
            let (connected, fake) = try await connectedClient()
            await fake.emit(Data("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"primary\":{\"\(field)\":\(invalid)}}}}\n".utf8))
            try await eventually { await fake.requestIDs().count == 3 }
            await fake.emit(Fixtures.response(id: await fake.requestIDs()[2], rateLimits: Fixtures.snapshotJSON))
            try await eventually { await connected.snapshot().fiveHour.remainingPercent == 80 }
            try await connected.close()
        }
    }

    private func connectedClient(
        calibrationInterval: Duration = .seconds(120)
    ) async throws -> (AppServerClient, FakeAppServerTransport) {
        let transport = FakeAppServerTransport()
        let client = AppServerClient(
            executable: executable,
            transportFactory: { transport },
            deadline: .seconds(1),
            calibrationInterval: calibrationInterval
        )
        let started = Task { try await client.start() }
        try await completeHandshake(transport: transport)
        _ = try await started.value
        return (client, transport)
    }

    private func completeHandshake(transport: FakeAppServerTransport) async throws {
        try await eventually { await transport.requestIDs().count == 1 }
        await transport.emit(Fixtures.response(id: await transport.requestIDs()[0], rateLimits: "{}"))
        try await eventually { await transport.requestIDs().count == 2 }
        await transport.emit(Fixtures.response(id: await transport.requestIDs()[1], rateLimits: Fixtures.snapshotJSON))
    }
}

private func collectUntilFinished(
    _ stream: AsyncStream<UsageSnapshot>,
    timeout: Duration
) async -> [UsageSnapshot]? {
    await withTaskGroup(of: [UsageSnapshot]?.self) { group in
        group.addTask {
            var values: [UsageSnapshot] = []
            for await value in stream { values.append(value) }
            return values
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private final class TransportSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakeAppServerTransport]
    init(_ transports: [FakeAppServerTransport]) { self.transports = transports }
    func next() -> FakeAppServerTransport {
        lock.withLock { transports.removeFirst() }
    }
}

private final class WeakClientBox: @unchecked Sendable {
    weak var value: AppServerClient?
    init(_ value: AppServerClient?) { self.value = value }
}

private actor CompletionCounter {
    private(set) var value = 0
    func mark() { value += 1 }
}

private struct FakeInstallationInspector: CodexInstallationInspecting {
    let bundleID: String?
    let executable: Bool
    let capability: Bool
    var canonical = true
    var signature = true
    var capabilityCounter: CallCounter?
    func bundleIdentifier(at applicationURL: URL) -> String? { bundleID }
    func isExecutableFile(at executableURL: URL) -> Bool { executable }
    func isCanonicalTrustedInstallation(applicationURL: URL, executableURL: URL) -> Bool { canonical }
    func hasValidCodexSignature(applicationURL: URL) -> Bool { signature }
    func supportsAppServer(executableURL: URL) async -> Bool { capabilityCounter?.increment(); return capability }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

extension FakeAppServerTransport {
    func setSpawnFailure() { spawnFailure = true }
    func setWriteFailure(at index: Int) { writeFailureAt = index }
    func setHangsOnStart() { hangsOnStart = true }
    func setHangsOnWrite() { hangsOnWrite = true }
    func setCloseDelay(_ value: Duration) { closeDelay = value }
    func setCloseFailures(_ value: Int) { closeFailures = value }
}

private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline { throw AppServerClientError.deadlineExceeded }
        await Task.yield()
    }
}
