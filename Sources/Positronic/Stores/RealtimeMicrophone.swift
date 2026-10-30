import Foundation
import OSLog
import AVFoundation
import AudioToolbox
import ModelAPI

/// AudioQueue keeps one input stream open. Its fixed buffers avoid capture-session
/// preroll bursts. Hardware-owned samples are copied before each buffer is reused.
final class RealtimeMicrophone: @unchecked Sendable {
    private let bridge: RealtimeCaptureBridge
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var active = false
    private var queue: AudioQueueRef?
    private var delivered = 0
    private var started = ContinuousClock.now
    private static let log = Logger(subsystem: "nl.lucasilverentand.mac-model-api", category: "MicrophoneTiming")
    init(bridge: RealtimeCaptureBridge) { self.bridge = bridge }
    deinit { stop() }
    func start() throws {
        stop()
        var description = format.streamDescription.pointee
        var created: AudioQueueRef?
        let callbacks = DispatchQueue(label: "Positronic.MicrophoneInput", qos: .userInteractive)
        var status = AudioQueueNewInputWithDispatchQueue(&created, &description, 0, callbacks) { @Sendable [weak self] queue, buffer, time, _, _ in
            self?.receive(queue, buffer: buffer, hostTime: time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : 0)
        }
        guard status == noErr, let created else { throw ModelAPIError.unavailable("Could not open the microphone input queue (\(status)).") }
        queue = created
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(created, 480 * 4, &buffer)
            guard status == noErr, let buffer else { stop(); throw ModelAPIError.unavailable("Could not allocate the bounded microphone buffers.") }
            status = AudioQueueEnqueueBuffer(created, buffer, 0, nil)
            guard status == noErr else { stop(); throw ModelAPIError.unavailable("Could not prepare the microphone input buffers.") }
        }
        lock.lock(); active = true; lock.unlock()
        delivered = 0; started = .now
        status = AudioQueueStart(created, nil)
        guard status == noErr else { stop(); throw ModelAPIError.unavailable("Could not start microphone input (\(status)).") }
    }
    func receive(_ queue: AudioQueueRef, buffer: AudioQueueBufferRef, hostTime: UInt64) {
        lock.lock(); let running = active; lock.unlock()
        guard running else { return }
        let bytes = buffer.pointee.mAudioDataByteSize
        delivered += Int(bytes / 4)
        if delivered == 480 || (delivered <= 30720 && delivered % 15360 == 0) {
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            Self.log.info("Input timing: \(self.delivered) samples delivered in \(seconds) seconds; timestamp valid \(hostTime != 0).")
        }
        if bytes > 0 {
            guard bytes <= 480 * 4, bytes % 4 == 0 else {
                bridge.continuation.finish(throwing: ModelAPIError.invalid("Invalid microphone input buffer.")); return
            }
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: buffer.pointee.mAudioData))
            bridge.receive(format: format, frames: bytes / 4, buffers: &buffers, hostSeconds: hostTime == 0 ? nil : AVAudioTime.seconds(forHostTime: hostTime))
        }
        lock.lock(); let requeue = active; lock.unlock()
        if requeue, AudioQueueEnqueueBuffer(queue, buffer, 0, nil) != noErr {
            bridge.continuation.finish(throwing: ModelAPIError.unavailable("The microphone device stopped delivering audio."))
        }
    }
    func stop() {
        lock.lock(); active = false; lock.unlock()
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
    }
}
