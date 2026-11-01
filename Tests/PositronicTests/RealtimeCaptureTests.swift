import XCTest
import AVFoundation
@testable import Positronic

final class RealtimeCaptureTests: XCTestCase, @unchecked Sendable {
    func testHardwareRateBuffersProduceBoundedPCMOnBackgroundAudioThread() async throws {
        let frames = try await Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(25))
            let bridge = try RealtimeCaptureBridge(source: format, continuation: continuation, options: .init(echoCancellation: false, voiceFocus: false))
            for _ in 0..<20 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
                buffer.frameLength = 512
                buffer.floatChannelData![0].initialize(repeating: 0.25, count: 512)
                bridge.receive(format: format, frames: 512, buffers: buffer.audioBufferList)
                buffer.floatChannelData![0].update(repeating: .nan, count: 512)
            }
            bridge.finish()
            var values: [Data] = []
            for try await frame in stream { values.append(frame) }
            return values
        }.value
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.count == 2560 })
        XCTAssertTrue(frames.contains { $0.contains { $0 != 0 } })
    }
}
