import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

private actor RealtimeLog {
    var values: [RealtimeEvent] = []
    func append(_ event: RealtimeEvent) { values.append(event) }
    func has(_ type: String) -> Bool { values.contains { $0.type == type } }
}
private actor DuplexFixture: RealtimeBackend {
    var starts = 0; var steps = 0; var stops = 0
    var delay: Duration = .zero
    func slow() { delay = .milliseconds(250) }
    func begin(_ configuration: RealtimeConfiguration) async throws { starts += 1 }
    func step(_ pcm: Data) async throws -> [RealtimeEvent] {
        steps += 1; if delay != .zero { try await Task.sleep(for: delay) }
        return [.init("response.text.delta", delta: "hello"), .init("output_audio.delta", audio: Data(repeating: 0, count: 3528).base64EncodedString(), sampleRate: 22050)]
    }
    func end() { stops += 1 }
}
private final class RealtimeProbe: @unchecked Sendable {
    let lock = NSLock(); var pressure: Int32 = 1
    func set(_ value: Int32) { lock.lock(); pressure = value; lock.unlock() }
    func snapshot() -> ResourceSnapshot { lock.lock(); defer { lock.unlock() }; return .init(physical: 36 << 30, available: 32 << 30, disk: 100 << 30, pressure: pressure) }
}
final class RealtimeTests: XCTestCase, @unchecked Sendable {
    private func until(_ check: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<500 { if try await check() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Realtime condition did not settle within the bounded fixture wait.")
    }
    func testConfigurationCannotSelectCloudOrUnboundedContext() throws {
        try RealtimeConfiguration().validate()
        XCTAssertThrowsError(try RealtimeConfiguration(model: "apple-pcc").validate())
        XCTAssertThrowsError(try RealtimeConfiguration(language: "nl").validate())
        XCTAssertThrowsError(try RealtimeConfiguration(instructions: String(repeating: "x", count: 1025)).validate())
        XCTAssertThrowsError(try RealtimeConfiguration(maxDurationSeconds: 601).validate())
        checkEqual(AudioCatalog.presets.first { $0.id == RealtimeConfiguration.modelID }?.capability, .conversation)
        checkTrue((AudioCatalog.budget(RealtimeConfiguration.modelID) ?? 0) > 8 << 30)
    }
    private func masked(_ data: Data, opcode: UInt8 = 1, final: Bool = true) -> Data {
        let mask: [UInt8] = [1,2,3,4]; var bytes = Data([opcode | (final ? 128 : 0)])
        if data.count < 126 { bytes.append(UInt8(data.count) | 128) }
        else { bytes.append(126 | 128); bytes.append(UInt8(data.count >> 8)); bytes.append(UInt8(data.count & 255)) }
        bytes.append(contentsOf: mask); bytes.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] }); return bytes
    }
    func testWebSocketRFCHandshakeAndFragmentation() throws {
        let raw = Data("GET /v1/realtime HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)
        checkEqual(try WebSocketFrames.acceptKey(XCTUnwrap(HTTPParser.parse(raw))), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        var parser = WebSocketFrames(); var frames: [WebSocketFrames.Frame] = []
        let data = masked(Data("hel".utf8), final: false) + masked(Data([5]), opcode: 9) + masked(Data("lo".utf8), opcode: 0)
        for byte in data { frames += try parser.append(Data([byte])) }
        checkEqual(frames.map(\.opcode), [9,1]); checkEqual(frames.last?.payload, Data("hello".utf8))
        XCTAssertThrowsError(try parser.append(WebSocketFrames.encode(Data("unmasked".utf8))))
        var big = WebSocketFrames()
        XCTAssertThrowsError(try big.append(Data([0x81,0xff,0,0,0,0,0,2,0,0])))
    }
    func testAdmittedConversationStreamsAndDeletesContextAtCompletion() async throws {
        let queue = fixtureQueue(), backend = DuplexFixture(), log = RealtimeLog()
        let service = RealtimeService(jobs: queue, backend: backend, validate: { _ in })
        let session = service.makeSession { await log.append($0) }
        let owner = UUID(); let job = try await service.submit(.init(maxDurationSeconds: 10), owner: owner, session: session)
        try await until { await log.has("session.ready") }
        try await session.receive(.init("input_audio.append", audio: Data(repeating: 0, count: 2560).base64EncodedString()))
        try await until { await log.has("output_audio.delta") }
        let frames = await log.values.filter { $0.type == "output_audio.delta" }
        checkEqual(frames.first?.sampleRate, 22050); checkEqual(frames.first?.sequence, 1)
        try await session.receive(.init("playback.ack", sequence: 1, epoch: 0))
        try await session.receive(.init("input_audio.commit"))
        let playback = Task {
            while !Task.isCancelled {
                let pending = await log.values.last { $0.type == "output_audio.delta" }
                if let pending, let sequence = pending.sequence, let epoch = pending.epoch {
                    try await session.receive(.init("playback.ack", sequence: sequence, epoch: epoch))
                }
                if await log.has("session.done") { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { playback.cancel() }
        _ = try await queue.wait(job.id)
        checkTrue(awaitValue(await log.has("session.done")))
        checkEqual(await queue.list(owner: UUID()).count, 0)
        checkGreater(await backend.stops, 0)
        let result = try await queue.result(job.id, owner: owner)
        checkFalse(String(decoding: try Data(contentsOf: XCTUnwrap(result.file)), as: UTF8.self).contains("hello"))
        await queue.shutdown()
    }
    func testPressureBlocksWithoutStartingAndRevocationCancelsQueue() async throws {
        let probe = RealtimeProbe(); probe.set(2)
        let queue = JobQueue(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), interval: .milliseconds(5), probe: { probe.snapshot() })
        let backend = DuplexFixture(), service = RealtimeService(jobs: queue, backend: backend, validate: { _ in })
        let owner = UUID(), session = service.makeSession { _ in }
        let job = try await service.submit(.init(), owner: owner, session: session)
        try await until { try await queue.job(job.id).state == .waitingForResources }
        checkEqual(await backend.starts, 0)
        await queue.revoke(owner)
        checkEqual(try await queue.job(job.id).state, .cancelled)
        do { _ = try await service.submit(.init(), owner: owner, session: session); XCTFail("Revoked key admitted") } catch ModelAPIError.unauthorized {}
        await queue.shutdown()
    }
    func testBargeInClearsPlaybackAndDiscardsInFlightOldEpoch() async throws {
        let queue = fixtureQueue(), backend = DuplexFixture(), log = RealtimeLog(); await backend.slow()
        let service = RealtimeService(jobs: queue, backend: backend, validate: { _ in })
        let session = service.makeSession { await log.append($0) }
        let job = try await service.submit(.init(), session: session)
        try await until { await backend.steps > 0 }
        let voice = Data(repeating: 50, count: 2560).base64EncodedString()
        try await session.receive(.init("input_audio.append", audio: voice)); try await session.receive(.init("input_audio.append", audio: voice))
        try await until { await log.has("output_audio.clear") }
        try await Task.sleep(for: .milliseconds(300))
        checkFalse(awaitValue(await log.has("output_audio.delta")))
        checkTrue(awaitValue(await log.has("input_audio.speech_started")))
        try await queue.cancel(job.id)
        await queue.shutdown()
    }
    func testRunningMemoryPressureCancelsAndReleasesWorker() async throws {
        let probe = RealtimeProbe()
        let queue = JobQueue(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), interval: .milliseconds(5), probe: { probe.snapshot() })
        let backend = DuplexFixture(), log = RealtimeLog(), service = RealtimeService(jobs: queue, backend: backend, validate: { _ in })
        let session = service.makeSession { await log.append($0) }; let job = try await service.submit(.init(), session: session)
        try await until { await log.has("session.ready") }; probe.set(2)
        try await until { try await queue.job(job.id).state == .failed }
        try await until { await backend.stops > 0 }
        await queue.shutdown()
    }
    func testAuthenticatedSwiftWebSocketClientAndDisconnectCancellation() async throws {
        let queue = fixtureQueue(), backend = DuplexFixture(), service = RealtimeService(jobs: queue, backend: backend, validate: { _ in })
        let owner = UUID(), ready = expectation(description: "Listener")
        let server = try LoopbackServer(port: 0, authorizeUpload: { $0.bearer == "fixture-key" && $0.headers["origin"] == nil }, realtime: { _, socket in
            await service.serve(socket, owner: owner, enabled: { _ in true })
        }) { _ in .error("Not found", status: 404) }
        let run = Task { try await server.run { ready.fulfill() } }; await fulfillment(of: [ready], timeout: 3)
        let base = URL(string: "http://127.0.0.1:\(try XCTUnwrap(server.port))")!
        let client = try RealtimeConnection(baseURL: base, apiKey: "fixture-key")
        checkEqual(try await client.receive().type, "session.created"); try await client.configure(.init())
        var id: UUID?
        while true {
            let event = try await client.receive(); if let job = event.job { id = job.id }
            if event.type == "session.ready" { break }
        }
        try await client.appendAudio(Data(repeating: 0, count: 2560))
        while true { let event = try await client.receive(); if event.type == "output_audio.delta" { try await client.acknowledge(try XCTUnwrap(event.sequence), epoch: try XCTUnwrap(event.epoch)); break } }
        await client.close()
        let jobID = try XCTUnwrap(id)
        try await until { try await queue.job(jobID).state == .cancelled }
        try await until { await backend.stops > 0 }
        server.stop(); _ = try await run.value; await queue.shutdown()
    }
    private func awaitValue(_ value: Bool) -> Bool { value }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a,b,file:file,line:line) }
private func checkTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a,file:file,line:line) }
private func checkFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(a,file:file,line:line) }
private func checkGreater<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertGreaterThan(a,b,file:file,line:line) }
extension RealtimeTests {
    func testRealtimeUsesAudioDriveAndPreservesDownloadReserve() throws {
        var config = ServiceConfiguration(); config.assetsPath = ""
        let preset = try XCTUnwrap(AudioCatalog.presets.first { $0.capability == .conversation })
        let enough = try ModelLibrary(configuration: config, capacity: { url in
            checkEqual(url, AudioCatalog.directory); return 40 << 30
        })
        checkEqual(enough.downloadRestriction(preset), nil)
        let low = try ModelLibrary(configuration: config, capacity: { _ in 34 << 30 })
        checkTrue(low.downloadRestriction(preset)?.contains("Needs") == true)
    }
    func testInputBeforeAdmissionAndInvalidFramesAreRejected() async throws {
        let backend = DuplexFixture(), log = RealtimeLog()
        let session = RealtimeSession(backend: backend) { await log.append($0) }
        do { try await session.receive(.init("input_audio.append", audio: "AAAA")); XCTFail("Input accepted before ready") } catch {}
        checkEqual(await backend.starts, 0)
    }
    func testPlaybackWithoutAcknowledgementsStopsRatherThanGrowing() async throws {
        let queue = fixtureQueue(), backend = DuplexFixture(), log = RealtimeLog()
        let service = RealtimeService(jobs: queue, backend: backend, validate: { _ in })
        let session = service.makeSession { await log.append($0) }; let job = try await service.submit(.init(), session: session)
        try await until { try await queue.job(job.id).state == .failed }
        let result = try await queue.job(job.id)
        checkTrue(result.message?.contains("Playback") == true)
        let count = await log.values.filter { $0.type == "output_audio.delta" }.count
        checkTrue(count <= 25); checkGreater(await backend.stops, 0)
        await queue.shutdown()
    }
    func testBadKeyAndBrowserOriginCannotUpgrade() async throws {
        let ready = expectation(description: "Auth listener")
        let server = try LoopbackServer(port: 0, authorizeUpload: { $0.bearer == "fixture-key" && $0.headers["origin"] == nil }, realtime: { _, socket in XCTFail("Unauthorized WebSocket upgraded"); socket.close() }) { _ in .error("Not found", status: 404) }
        let run = Task { try await server.run { ready.fulfill() } }; await fulfillment(of: [ready], timeout: 3)
        for (token, origin) in [("wrong-key", Optional<String>.none), ("fixture-key", "https://example.test")] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(try XCTUnwrap(server.port))/v1/realtime")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue(origin, forHTTPHeaderField: "Origin")
            let (_, response) = try await HTTPTransport.send(request)
            checkEqual(response.statusCode, 401)
        }
        server.stop(); _ = try await run.value
    }
}
extension RealtimeTests {
    func testBudgetIncludesActualWeightsAndSessionGrowth() {
        let short = RealtimeMemoryBudget.estimate(weightBytes: 9 << 30, seconds: 40)
        let long = RealtimeMemoryBudget.estimate(weightBytes: 9 << 30, seconds: 600)
        checkTrue((short ?? 0) > 9 << 30); checkGreater(long ?? 0, short ?? 0)
        checkEqual(RealtimeMemoryBudget.estimate(weightBytes: 0, seconds: 40), nil)
        checkEqual(RealtimeMemoryBudget.estimate(weightBytes: 9 << 30, seconds: 601), nil)
    }
}
