import XCTest
@testable import Positronic

final class LocalVoiceDSPTests: XCTestCase {
    private struct Signal {
        var seed: UInt32 = 917
        mutating func noise(_ amplitude: Float) -> [Float] {
            (0..<480).map { _ in seed = seed &* 1664525 &+ 1013904223; return (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * amplitude }
        }
    }
    private func energy(_ values: [Float]) -> Double { values.reduce(0) { $0 + Double($1 * $1) } }
    func testEchoCancellationReducesDelayedPlaybackAndPreservesNearSpeech() throws {
        let echo = try LocalVoiceDSP(options: .init(echoCancellation: true, voiceFocus: false))
        let plain = try LocalVoiceDSP(options: .init(echoCancellation: false, voiceFocus: false))
        var signal = Signal(), history = [[Float]](repeating: [Float](repeating: 0, count: 480), count: 2)
        var remaining = 0.0, original = 0.0, nearEnergy = 0.0
        for frame in 0..<700 {
            let reference = signal.noise(0.25)
            try echo.render(reference)
            let delayed = history.removeFirst(); history.append(reference)
            let input = delayed.enumerated().map { index, sample -> Float in
                let t = Double(frame * 480 + index) / 48000
                let near = frame >= 600 ? 0.08 * sin(2 * .pi * 220 * t) + 0.04 * sin(2 * .pi * 440 * t) : 0
                return sample * 0.6 + Float(near)
            }
            let cleaned = try echo.capture(input), raw = try plain.capture(input)
            if frame >= 500 && frame < 600 { remaining += energy(cleaned); original += energy(raw) }
            if frame >= 650 { nearEnergy += energy(cleaned) }
        }
        let attenuation = 10 * log10(original / max(remaining, 1e-20))
        print("DSP_MEASUREMENT delayed_echo_attenuation_db=\(attenuation)")
        XCTAssertGreaterThan(attenuation, 12)
        XCTAssertGreaterThan(sqrt(nearEnergy / Double(50 * 160)), 0.025)
    }
    func testNeuralCleanupReducesSteadyBackgroundNoiseWithinRealtimeBudget() throws {
        let clean = try LocalVoiceDSP(options: .init(echoCancellation: false, voiceFocus: true))
        let plain = try LocalVoiceDSP(options: .init(echoCancellation: false, voiceFocus: false))
        var signal = Signal(), reduced = 0.0, original = 0.0
        let start = ContinuousClock.now
        for frame in 0..<400 {
            let input = signal.noise(0.06)
            let output = try clean.capture(input), raw = try plain.capture(input)
            if frame >= 300 { reduced += energy(output); original += energy(raw) }
            if frame == 0 { XCTAssertGreaterThan(output.count, 0); XCTAssertLessThanOrEqual(output.count, 160) }
            else { XCTAssertEqual(output.count, 160) }
        }
        let elapsed = start.duration(to: .now).components
        let milliseconds = (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 1000 / 400
        print("DSP_MEASUREMENT noise_attenuation_db=\(10 * log10(original / max(reduced, 1e-20))) processing_ms_per_10ms_frame=\(milliseconds)")
        XCTAssertLessThan(reduced, original * 0.3)
        XCTAssertLessThan(milliseconds, 10)
    }
    func testBatchedSpeakerReferenceUsesCaptureClockAndStaysBounded() {
        var reference = EchoReferenceHistory()
        reference.append((0..<4800).map(Float.init), at: 1)
        let frame = reference.frame(at: 1.005)
        XCTAssertEqual(frame.first, 240); XCTAssertEqual(frame.last, 719)
        XCTAssertEqual(reference.frame(at: 0), [Float](repeating: 0, count: 480))
        for index in 0..<20 { reference.append([Float](repeating: Float(index), count: 4800), at: 2 + Double(index) / 10) }
        XCTAssertLessThanOrEqual(reference.sampleCount, 96000)
        XCTAssertEqual(reference.frame(at: 3.95).first, 19)
    }
    func testQuietMicrophoneInputRemainsRealtime() throws {
        let dsp = try LocalVoiceDSP()
        let quiet = [Float](repeating: 1e-20, count: 480)
        let begin = ContinuousClock.now
        for _ in 0..<300 { try dsp.render(quiet); _ = try dsp.capture(quiet) }
        let elapsed = begin.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("DSP_MEASUREMENT quiet_frame_ms=\(seconds * 1000 / 300)")
        XCTAssertLessThan(seconds, 3)
    }
    func testDriverBurstUsesAudioDurationInsteadOfAPIFrameCount() {
        var budget = AudioHandoffBudget()
        for _ in 0..<64 { XCTAssertTrue(budget.reserve(bytes: 1920, micros: 10000, render: false)) }
        for _ in 0..<10 { XCTAssertTrue(budget.reserve(bytes: 153600, micros: 100000, render: true)) }
        for _ in 0..<136 { XCTAssertTrue(budget.reserve(bytes: 1920, micros: 10000, render: false)) }
        XCTAssertFalse(budget.reserve(bytes: 1920, micros: 10000, render: false))
        budget.release(bytes: 1920, micros: 10000, render: false)
        XCTAssertTrue(budget.reserve(bytes: 1920, micros: 10000, render: false))
        XCTAssertLessThanOrEqual(budget.bytes, 4 << 20)
    }
    func testByteBudgetRemainsIndependentOfAudioDuration() {
        var budget = AudioHandoffBudget()
        XCTAssertTrue(budget.reserve(bytes: 3 << 20, micros: 10000, render: true))
        XCTAssertFalse(budget.reserve(bytes: 2 << 20, micros: 10000, render: false))
        budget.release(bytes: 3 << 20, micros: 10000, render: true)
        XCTAssertEqual(budget.buffers, 0); XCTAssertEqual(budget.bytes, 0)
        XCTAssertTrue(budget.reserve(bytes: 2 << 20, micros: 10000, render: false))
    }
    func testMalformedFramesFailBeforeNativeProcessing() throws {
        let dsp = try LocalVoiceDSP()
        XCTAssertThrowsError(try dsp.capture([Float](repeating: 0, count: 479)))
        XCTAssertThrowsError(try dsp.render([Float](repeating: .nan, count: 480)))
        XCTAssertThrowsError(try dsp.capture([Float](repeating: .infinity, count: 480)))
        let output = try dsp.capture([Float](repeating: 0, count: 480))
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }
}
