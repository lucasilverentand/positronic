import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct AudioResultPreview: View {
    @Bindable var store: AppStore
    let jobID: UUID
    @State private var player: AVAudioPlayer?
    @State private var playbackTask: Task<Void,Never>?
    @State private var exporting = false
    @State private var document: SampleAudioDocument?
    @State private var error = ""
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Audio sample ready",systemImage:"waveform").font(.headline)
            HStack {
                Button("Play") { stopPlayback();playbackTask = Task {
                    do { let result=try await store.jobs.result(jobID);try Task.checkCancellation();if let file=result.file { player?.stop();player=try AVAudioPlayer(contentsOf:file);player?.play() } }
                    catch is CancellationError {}
                    catch { self.error="This sample is no longer available. Generate another snippet." }
                } }
                Button("Stop") { stopPlayback() }
                Button("Export WAV…") { Task {
                    do { let result=try await store.jobs.result(jobID);if let file=result.file { document=SampleAudioDocument(file:file);exporting=true } }
                    catch { self.error=error.localizedDescription }
                } }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of:jobID) { stopPlayback();player=nil;error="" }
        .onDisappear { stopPlayback() }
        .fileExporter(isPresented:$exporting,document:document,contentType:.wav) { result in
            if case .failure(let failure)=result { error=failure.localizedDescription };document=nil
        }
    }
    private func stopPlayback() { playbackTask?.cancel();playbackTask=nil;player?.stop() }
}
private struct SampleAudioDocument: FileDocument {
    static var readableContentTypes:[UTType] { [.wav] }
    let file:URL?
    init(file:URL) { self.file=file }
    init(configuration:ReadConfiguration) throws { file=nil }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper {
        guard let file else { throw CocoaError(.fileReadNoSuchFile) };return try FileWrapper(url:file,options:[])
    }
}
