import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ModelAPI
import ModelService

struct AudioPage: View {
    @Bindable var store: AppStore
    private var capture: AudioCapture { store.audioCapture }
    @State private var language = "en"
    @State private var text = ""
    @State private var transcript = ""
    @State private var importing = false
    @State private var currentJob: UUID?
    @State private var currentSpeech: UUID?
    @State private var player: AVAudioPlayer?
    @State private var exporting = false
    @State private var exportDocument: AudioExportDocument?
    var body: some View {
        PageHeading(title: "Audio", detail: "English and Dutch transcription and speech, entirely on this Mac.")
        if !AudioCatalog.runtimeReady {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Prepare local audio").font(.headline)
                    Text("Install the private MLX Audio runtime, then download and enable Whisper and Chatterbox in Discover and Your models.").foregroundStyle(.secondary)
                    Button("Prepare audio runtime") { Task { await store.prepareAudioRuntime() } }.disabled(store.busy || store.managingModels)
                }.padding(12)
            }
        }
        if AudioCatalog.runtimeReady && !AudioCatalog.ids.allSatisfy(store.configuration.audioModels.contains) {
            Text("Download the audio models in Discover, then enable them in Your models to use these tools.").foregroundStyle(.secondary)
        }
        Picker("Language", selection: $language) { Text("English").tag("en"); Text("Dutch").tag("nl") }.frame(maxWidth: 280).disabled(capture.recording)
        GroupBox("Transcribe audio") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import a recording up to 64 MiB and 30 minutes, or record your microphone. Transcription starts after recording ends.").foregroundStyle(.secondary)
                HStack {
                    Button("Import audio…") { importing = true }.disabled(capture.recording)
                    if capture.recording {
                        Label("Recording…", systemImage: "record.circle").foregroundStyle(.red)
                        Button("Stop and transcribe") { capture.stop() }
                        Button("Cancel recording") { capture.cancel() }
                    } else { Button("Record microphone") { Task { await capture.start() } } }
                }.disabled(!store.queueReady || !store.configuration.audioModels.contains("whisper-large-v3-turbo"))
                if !capture.message.isEmpty { Text(capture.message).foregroundStyle(.secondary) }
                if !transcript.isEmpty {
                    Text(transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy transcript") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string) }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Create speech") {
            VStack(alignment: .leading, spacing: 14) {
                TextEditor(text: $text).frame(minHeight: 110).font(.body)
                HStack {
                    Text("\(text.count) / 5000 · Default voice").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Generate speech") { Task { await submitSpeech() } }
                        .buttonStyle(.borderedProminent).disabled(!store.queueReady || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 5000 || !store.configuration.audioModels.contains("chatterbox-multilingual-v3"))
                }
                if let currentSpeech, store.jobRecords.first(where: { $0.id == currentSpeech })?.state == .succeeded {
                    HStack {
                        Button("Play") { Task { await play(currentSpeech) } }
                        Button("Stop playback") { player?.stop() }
                        Button("Export WAV…") { Task {
                            do { let result = try await store.jobs.result(currentSpeech); if let file = result.file { exportDocument = AudioExportDocument(file: file); exporting = true } }
                            catch { store.message = error.localizedDescription }
                        } }
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        if let currentJob, let job = store.jobRecords.first(where: { $0.id == currentJob }) {
            HStack {
                Text(job.message ?? job.state.rawValue).foregroundStyle(.secondary)
                Spacer()
                if !job.state.terminal { Button("Cancel job") { Task { try? await store.jobs.cancel(currentJob) } } }
            }
        }
        Text("Audio is never sent to Private Cloud Compute. Inputs are deleted after completion or cancellation; results expire after 30 minutes.").font(.caption).foregroundStyle(.secondary)
            .task {
                while !Task.isCancelled {
                    await store.refreshJobs()
                    if let currentJob, store.jobRecords.first(where: { $0.id == currentJob })?.state == .succeeded, currentSpeech != currentJob {
                        if let result = try? await store.jobs.result(currentJob), let file = result.file, let data = try? Data(contentsOf: file), let response = try? JSONDecoder().decode(Transcript.self, from: data) { transcript = response.text }
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
            .onDisappear { capture.cancel(); player?.stop() }
            .onChange(of: capture.completed) { if let file = capture.completed { capture.completed = nil; Task { await submitFile(file, imported: false) } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result { case .success(let url): Task { await submitFile(url, imported: true) }; case .failure(let error): store.message = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .wav) { result in
                if case .failure(let error) = result { store.message = error.localizedDescription }; exportDocument = nil
            }
    }
    private func submitFile(_ source: URL, imported: Bool) async {
        let access = imported ? source.startAccessingSecurityScopedResource() : false
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var input = source
        do {
            if imported {
                try AudioIO.validate(source); try ResourceMonitor.requireDisk(at: AudioCatalog.jobsDirectory, additional: 128 * 1024 * 1024)
                input = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".upload")
                try FileManager.default.copyItem(at: source, to: input); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
            }
            let job = try await store.audioService.submitTranscription(file: input, language: language)
            currentJob = job.id; transcript = ""; await store.refreshJobs()
        } catch { if !imported || input != source { try? FileManager.default.removeItem(at: input) }; store.message = error.localizedDescription }
    }
    private func submitSpeech() async {
        do { let job = try await store.audioService.submitSpeech(.init(input: text, language: language)); currentJob = job.id; currentSpeech = job.id; await store.refreshJobs() }
        catch { store.message = error.localizedDescription }
    }
    private func play(_ id: UUID) async {
        do { let result = try await store.jobs.result(id); if let file = result.file { player = try AVAudioPlayer(contentsOf: file); player?.play() } }
        catch { store.message = error.localizedDescription }
    }
}
private struct AudioExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    var file: URL?
    init(file: URL?) { self.file = file }
    init(configuration: ReadConfiguration) throws { file = nil }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let file else { throw CocoaError(.fileReadNoSuchFile) }; return try FileWrapper(url: file, options: [])
    }
}
