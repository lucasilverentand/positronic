import Foundation
import AVFoundation
import Observation
import ModelService

@MainActor @Observable
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    var recording = false
    var completed: URL?
    var message = ""
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var cancelled = false
    private var preparing = false
    func start() async {
        guard !recording, !preparing else { return }; preparing = true; defer { preparing = false }; message = ""; completed = nil; cancelled = false
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted: Bool
        if permission == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .audio) }
        else { granted = permission == .authorized }
        guard !cancelled else { return }
        guard granted else { message = "Microphone access is disabled. Allow Positronic in System Settings, or import an audio file."; return }
        do {
            try ResourceMonitor.requireDisk(at: AudioCatalog.jobsDirectory, additional: 64 * 1024 * 1024)
            let destination = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let recorder = try AVAudioRecorder(url: destination, settings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:16000, AVNumberOfChannelsKey:1, AVLinearPCMBitDepthKey:16, AVLinearPCMIsFloatKey:false])
            recorder.delegate = self; self.recorder = recorder; file = destination
            guard recorder.record(forDuration: 1800) else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path); recording = true
        } catch { if let file { try? FileManager.default.removeItem(at: file) }; file = nil; recorder = nil; message = error.localizedDescription }
    }
    func stop() { recorder?.stop() }
    func cancel() { cancelled = true; if let completed { try? FileManager.default.removeItem(at: completed) }; completed = nil; recorder?.stop(); recorder = nil; recording = false; if let file { try? FileManager.default.removeItem(at: file) }; file = nil }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let finished = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let owned = self.recorder, ObjectIdentifier(owned) == finished else { return }; self.recording = false
            if flag && !self.cancelled { self.completed = self.file; self.file = nil }
            else if let file = self.file { try? FileManager.default.removeItem(at: file) }
            self.recorder = nil
        }
    }
}
