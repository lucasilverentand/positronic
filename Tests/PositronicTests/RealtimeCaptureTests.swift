import XCTest
import AVFoundation
@testable import Positronic

final class RealtimeCaptureTests: XCTestCase, @unchecked Sendable {
    func testHardwareRateBuffersProduceBoundedPCMOnBackgroundAudioThread() async throws {
        let frames = try await Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(25))
            let bridge = try RealtimeCaptureBridge(source: format, continuation: continuation)
            for _ in 0..<20 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
                buffer.frameLength = 512
                buffer.floatChannelData![0].initialize(repeating: 0.25, count: 512)
                let borrowed = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffer.audioBufferList, deallocator: nil)!
                borrowed.frameLength = 512
                bridge.receive(borrowed)
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
