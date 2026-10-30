import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService
final class LiveAudioTests: XCTestCase, @unchecked Sendable {
    func testOfflineEnglishAndDutchThroughScheduler() async throws {
        guard ProcessInfo.processInfo.environment["POSITRONIC_LIVE_AUDIO"] == "1" else { throw XCTSkip("Explicit physical-Mac audio validation only") }
        let runtime = AudioRuntime(), queue = JobQueue(waitLimit: 20)
        let snapshot = try ResourceMonitor.snapshot()
        if let reason = ResourceMonitor.restriction(snapshot,budget:AudioCatalog.budget("chatterbox-multilingual-v3"),diskBytes:64 << 20).reason {
            throw XCTSkip("Physical-Mac admission blocked: " + reason)
        }
        try await queue.start()
        await queue.configure(prepare: { model in
            if !(await runtime.loaded()).contains(where: { $0.id == model }) { await runtime.stop() }
        }, cancelWorker: { await runtime.stop() }, footprint: { try await runtime.memory() })
        let audio = AudioService(runtime: runtime, queue: queue, enabled: AudioCatalog.ids)
        do {
            for (language, expected) in [("en","robot"),("nl","robot")] {
                let speech = try await audio.submitSpeech(.init(input: language == "en" ? "The little robot is ready to help." : "De kleine robot staat klaar om te helpen.",language: language))
                let output = try await queue.wait(speech.id)
                XCTAssertEqual(output.type,"audio/wav")
                let source = try XCTUnwrap(output.file); try AudioIO.validate(source)
                let input = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                try FileManager.default.copyItem(at: source, to: input)
                let job = try await audio.submitTranscription(file: input, language: language)
                let data = try await queue.wait(job.id).data
                let transcript = try JSONDecoder().decode(Transcript.self, from: data)
                XCTAssertTrue(transcript.text.lowercased().contains(expected)); XCTAssertFalse(transcript.segments.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
            }
        } catch { await queue.shutdown(); throw error }
        await queue.shutdown()
        let remaining = await runtime.loaded(); XCTAssertTrue(remaining.isEmpty)
    }
}
