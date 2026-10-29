import Foundation
import AVFoundation
import ModelAPI

public enum AudioIO {
    public static let uploadLimit = 64 * 1024 * 1024
    public static func validate(_ file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= uploadLimit else { throw ModelAPIError.limit("Audio files must be between 1 byte and 64 MiB.") }
        let audio = try AVAudioFile(forReading: file)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= 1800 else { throw ModelAPIError.limit("Audio must contain at most 30 minutes of decodable sound.") }
    }
    public static func normalize(_ file: URL, to output: URL) async throws {
        let task = Task.detached(priority: .utility) {
            try validate(file)
            let source = try AVAudioFile(forReading: file)
            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: source.processingFormat, to: target),
                  let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192),
                  let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { throw ModelAPIError.invalid("Unsupported audio format.") }
            let destination = try AVAudioFile(forWriting: output, settings: target.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            var ended = false
            while true {
                try Task.checkCancellation()
                var error: NSError?
                var readError: (any Error)?
                let status = converter.convert(to: buffer, error: &error) { _, state in
                    if ended { state.pointee = .endOfStream; return nil }
                    if source.framePosition >= source.length { ended = true; state.pointee = .endOfStream; return nil }
                    do { try source.read(into: input, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(input.frameCapacity), source.length - source.framePosition))) }
                    catch { readError = error; ended = true; state.pointee = .endOfStream; return nil }
                    if input.frameLength == 0 { ended = true; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData; return input
                }
                if let readError { throw readError }; if let error { throw error }
                if buffer.frameLength > 0 { try destination.write(from: buffer) }
                if status == .endOfStream { break }
                if status == .error { throw ModelAPIError.invalid("Could not decode the audio recording.") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
