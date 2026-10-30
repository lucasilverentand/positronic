import Foundation
import Darwin
import AVFoundation
import OSLog
import ModelAPI
import CVoiceDSP

struct LocalVoiceOptions: Sendable {
    var echoCancellation = true
    var voiceFocus = true
}

/// One serial owner per stream. No files, network access or external models.
final class LocalVoiceDSP {
    private let state: OpaquePointer
    init(options: LocalVoiceOptions = .init()) throws {
        guard let value = pm_voice_create(options.echoCancellation ? 1 : 0, options.voiceFocus ? 1 : 0) else { throw ModelAPIError.unavailable("Local voice processing could not allocate its bounded state.") }
        state = value
    }
    deinit { pm_voice_destroy(state) }
    func render(_ samples: [Float]) throws {
        guard samples.count == 480, samples.allSatisfy(\.isFinite), samples.withUnsafeBufferPointer({ pm_voice_render(state, $0.baseAddress, 480) }) == 0 else { throw ModelAPIError.invalid("Invalid echo reference frame.") }
    }
    func capture(_ samples: [Float]) throws -> [Float] {
        guard samples.count == 480, samples.allSatisfy(\.isFinite) else { throw ModelAPIError.invalid("Invalid microphone processing frame.") }
        var output = [Float](repeating: 0, count: 160)
        let count = output.withUnsafeMutableBufferPointer { destination in samples.withUnsafeBufferPointer { source in
            pm_voice_capture(state, source.baseAddress, 480, destination.baseAddress, 160)
        } }
        guard count >= 0, count <= 160, output.prefix(Int(count)).allSatisfy(\.isFinite) else { throw ModelAPIError.unavailable("Local voice processing failed safely.") }
        return Array(output.prefix(Int(count)))
    }
}

/// Two seconds of speaker-reference audio, indexed by the device host clock.
struct EchoReferenceHistory {
    private var blocks: [(time: Double, samples: [Float])] = []
    private(set) var sampleCount = 0
    mutating func append(_ samples: [Float], at time: Double) {
        guard time.isFinite, !samples.isEmpty else { return }
        blocks.append((time, samples)); sampleCount += samples.count
        while sampleCount > 96000, !blocks.isEmpty {
            let excess = sampleCount - 96000
            if blocks[0].samples.count <= excess { sampleCount -= blocks.removeFirst().samples.count }
            else { blocks[0].samples.removeFirst(excess); blocks[0].time += Double(excess) / 48000; sampleCount -= excess }
        }
    }
    func frame(at time: Double) -> [Float] {
        var output = [Float](repeating: 0, count: 480)
        for block in blocks {
            guard block.time + Double(block.samples.count) / 48000 > time, block.time < time + 0.01 else { continue }
            let offset = Int(((block.time - time) * 48000).rounded())
            let lower = max(0, -offset), upper = min(block.samples.count, 480 - offset)
            if lower < upper { for index in lower..<upper { output[index + offset] = block.samples[index] } }
        }
        return output
    }
}

/// The transport packets may be 10 ms, while API frames are 80 ms. Bound time
/// and bytes independently so packetization cannot shrink the live audio budget.
struct AudioHandoffBudget {
    private(set) var buffers = 0
    private(set) var bytes = 0
    private var microphoneMicros: Int64 = 0
    private var referenceMicros: Int64 = 0
    mutating func reserve(bytes additional: Int, micros: Int64, render: Bool) -> Bool {
        guard additional >= 0, micros > 0, buffers < 256, additional <= (4 << 20) - bytes,
              micros <= 2_000_000 - (render ? referenceMicros : microphoneMicros) else { return false }
        buffers += 1; bytes += additional
        if render { referenceMicros += micros } else { microphoneMicros += micros }
        return true
    }
    mutating func release(bytes count: Int, micros: Int64, render: Bool) {
        buffers -= 1; bytes -= count
        if render { referenceMicros -= micros } else { microphoneMicros -= micros }
    }
}

/// Exclusively transferred to the serial processor after the hardware copy.
private final class OwnedAudioBlock: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Both the microphone and actual rendered playback enter the same bounded queue.
/// Conversion and adaptive/neural processing never run on the hardware IO thread.
final class RealtimeCaptureBridge: @unchecked Sendable {
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let dsp: LocalVoiceDSP
    private let lock = NSLock()
    private let conversionQueue = DispatchQueue(label: "Positronic.LocalVoiceProcessing", qos: .userInteractive)
    private var budget = AudioHandoffBudget()
    private var enabledSince: Double?
    private var enabled: Bool
    private var captureConverter: AVAudioConverter?
    private var renderConverter: AVAudioConverter?
    private var microphone = [Float]()
    private var reference = EchoReferenceHistory()
    private var microphoneStart: Double?
    private var delayed: [(time: Double?, samples: [Float])] = []
    private let echoEnabled: Bool
    private var pending = Data()
    private var sawInput = false
    private var sawPCM = false
    private var sawReference = false
    private var loggedSlow = false
    private var loggedPreloadDrop = false
    private static let log = Logger(subsystem: "nl.lucasilverentand.mac-model-api", category: "RealtimeCapture")
    init(source: AVAudioFormat, continuation: AsyncThrowingStream<Data, any Error>.Continuation, enabled: Bool = true, options: LocalVoiceOptions = .init()) throws {
        guard source.sampleRate > 0, source.channelCount > 0 else { throw ModelAPIError.unavailable("No active microphone format.") }
        self.continuation = continuation; self.enabled = enabled; echoEnabled = options.echoCancellation
        dsp = try LocalVoiceDSP(options: options)
        microphone.reserveCapacity(16864); delayed.reserveCapacity(25)
    }
    func receive(_ input: AVAudioPCMBuffer) { enqueue(format: input.format, frames: input.frameLength, buffers: input.audioBufferList, render: false, hostSeconds: nil) }
    func receiveRender(_ input: AVAudioPCMBuffer, at hostSeconds: Double) { enqueue(format: input.format, frames: input.frameLength, buffers: input.audioBufferList, render: true, hostSeconds: hostSeconds) }
    func receive(format: AVAudioFormat, frames: AVAudioFrameCount, buffers: UnsafePointer<AudioBufferList>, hostSeconds: Double? = nil) { enqueue(format: format, frames: frames, buffers: buffers, render: false, hostSeconds: hostSeconds) }
    private func enqueue(format: AVAudioFormat, frames: AVAudioFrameCount, buffers: UnsafePointer<AudioBufferList>, render: Bool, hostSeconds: Double?) {
        guard frames > 0 else { return }
        guard frames <= 16384, format.channelCount > 0, format.channelCount <= 32, format.sampleRate.isFinite, (8000...384000).contains(format.sampleRate) else {
            continuation.finish(throwing: ModelAPIError.invalid("Audio device format exceeds its processing bounds.")); return
        }
        let bytes = Int(frames) * Int(format.channelCount) * 4
        let micros = Int64((Double(frames) * 1_000_000 / format.sampleRate).rounded(.up))
        lock.lock()
        guard enabled else { lock.unlock(); return }
        if !render, let hostSeconds, let enabledSince, hostSeconds < enabledSince {
            let difference = enabledSince - hostSeconds, logDrop = !loggedPreloadDrop
            loggedPreloadDrop = true; lock.unlock()
            if logDrop { Self.log.info("Pre-readiness microphone frame discarded; clock difference \(difference) seconds.") }
            return
        }
        guard budget.reserve(bytes: bytes, micros: micros, render: render) else {
            enabled = false; lock.unlock()
            Self.log.error("Audio handoff exceeded two seconds or 4 MiB; stopping safely.")
            continuation.finish(throwing: ModelAPIError.unavailable("Local audio processing exceeded its two-second or 4 MiB bound.")); return
        }
        lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { releaseSlot(bytes: bytes, micros: micros, render: render); return }
        copy.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { releaseSlot(bytes: bytes, micros: micros, render: render); continuation.finish(throwing: ModelAPIError.invalid("Audio buffer channel mismatch.")); return }
        for index in target.indices {
            guard let from = source[index].mData, let to = target[index].mData, source[index].mDataByteSize >= target[index].mDataByteSize else { releaseSlot(bytes: bytes, micros: micros, render: render); continuation.finish(throwing: ModelAPIError.invalid("Audio buffer is incomplete.")); return }
            memcpy(to, from, Int(target[index].mDataByteSize))
        }
        let owned = OwnedAudioBlock(copy)
        conversionQueue.async {
            defer { self.releaseSlot(bytes: bytes, micros: micros, render: render) }
            self.lock.lock(); let active = self.enabled; self.lock.unlock()
            guard active else { return }
            let begin = ContinuousClock.now
            do { try self.convert(owned.buffer, render: render, hostSeconds: hostSeconds) }
            catch { self.continuation.finish(throwing: error) }
            let elapsed = begin.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if seconds > 0.02, !self.loggedSlow { self.loggedSlow = true; Self.log.info("Slow audio block: \(seconds) seconds, \(frames) input frames, reference \(render).") }
        }
    }
    private func releaseSlot(bytes: Int, micros: Int64, render: Bool) {
        lock.lock(); defer { lock.unlock() }
        budget.release(bytes: bytes, micros: micros, render: render)
    }
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if value && !enabled { enabledSince = AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
        enabled = value
    }
    func finish() { conversionQueue.async { self.continuation.finish() } }
    private func convert(_ input: AVAudioPCMBuffer, render: Bool, hostSeconds: Double?) throws {
        guard input.format.commonFormat == .pcmFormatFloat32, let channels = input.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameLength) else { throw ModelAPIError.invalid("Unsupported device audio format.") }
        mono.frameLength = input.frameLength
        let count = Int(input.format.channelCount), interleaved = input.format.isInterleaved
        for frame in 0..<Int(input.frameLength) {
            var sample: Float = 0
            for channel in 0..<count { sample += channels[interleaved ? 0 : channel][interleaved ? frame * count + channel : frame] }
            guard sample.isFinite else { throw ModelAPIError.invalid("Invalid audio sample.") }
            mono.floatChannelData![0][frame] = sample / Float(count)
        }
        let destination = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var converter = render ? renderConverter : captureConverter
        if converter == nil { converter = AVAudioConverter(from: monoFormat, to: destination) }
        guard let converter, converter.inputFormat == monoFormat else { throw ModelAPIError.unavailable("Audio device format changed; restart the conversation.") }
        if render { renderConverter = converter } else { captureConverter = converter }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48000 / input.format.sampleRate)) + 64
        guard capacity <= 50000, let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else { throw ModelAPIError.limit("Audio conversion buffer exceeds its bound.") }
        var supplied = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }; supplied = true; status.pointee = .haveData; return mono
        }
        if error != nil { throw ModelAPIError.unavailable("Device audio conversion failed.") }
        let values = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        if render {
            if !sawReference { sawReference = true; Self.log.info("First timestamped speaker reference received.") }
            if let hostSeconds { reference.append(values, at: hostSeconds) }
        } else {
            if !sawInput { sawInput = true; Self.log.info("First microphone buffer received for independent local voice processing.") }
            if microphone.isEmpty { microphoneStart = hostSeconds }
            microphone.append(contentsOf: values)
            while microphone.count >= 480 {
                delayed.append((microphoneStart, Array(microphone.prefix(480)))); microphone.removeFirst(480)
                if let start = microphoneStart { microphoneStart = start + 0.01 }
            }
        }
        try drain()
    }
    private func drain() throws {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        while let frame = delayed.first {
            // Engine taps deliver 100 ms batches. Hold near audio briefly so its
            // exact speaker reference is present, instead of dropping references.
            if echoEnabled, let time = frame.time, now - time < 0.12 { break }
            delayed.removeFirst()
            if let time = frame.time, now - time > 2 { continue }
            if echoEnabled { try dsp.render(frame.time.map { reference.frame(at: $0) } ?? [Float](repeating: 0, count: 480)) }
            let clean = try dsp.capture(frame.samples)
            for sample in clean {
                let value = UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32767))
                pending.append(UInt8(value & 255)); pending.append(UInt8(value >> 8))
            }
            while pending.count >= 2560 {
                if !sawPCM { sawPCM = true; Self.log.info("First cleaned 80 ms microphone frame produced.") }
                let result = continuation.yield(Data(pending.prefix(2560))); pending.removeFirst(2560)
                if case .dropped = result { throw ModelAPIError.unavailable("Microphone processing fell behind; stopped to keep audio current.") }
                if case .terminated = result { return }
            }
        }
        guard delayed.count <= 200 else { throw ModelAPIError.unavailable("Audio clock alignment exceeded its two-second bound.") }
    }
}
