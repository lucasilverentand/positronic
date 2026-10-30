import SwiftUI
import ModelAPI

struct ModelTestResultView: View {
    @Bindable var store: AppStore
    let result: ModelTestStore.Result
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            switch result {
            case .generation(let value):
                output(value.text);copyButton(value.text)
            case .decision(let value,let labels):
                if let answer=value.answers["result"] {
                    Text(labels[answer.choice] ?? answer.choice).font(.headline)
                    Text("Confidence: \(answer.confidence.formatted(.percent.precision(.fractionLength(0))))").font(.caption).foregroundStyle(.secondary)
                    ForEach(answer.probabilities.keys.sorted(),id:\.self) { key in
                        VStack(alignment:.leading,spacing:3) {
                            HStack { Text(labels[key] ?? key);Spacer();Text((answer.probabilities[key] ?? 0).formatted(.percent.precision(.fractionLength(1)))) }.font(.caption)
                            ProgressView(value:answer.probabilities[key] ?? 0)
                        }
                    }
                }
            case .embedding(let value):
                Text("\(value.embeddings.count) vectors · \(value.embeddings.first?.count ?? 0) dimensions").font(.headline)
                if let similarity=value.cosineSimilarity(between:0,and:1) {
                    Text("First two texts: \(similarity.formatted(.number.precision(.fractionLength(3)))) cosine similarity").font(.callout)
                    Text("Closer to 1 means the texts are more similar in this model’s vector space.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Vector preview") {
                    ForEach(value.embeddings.indices,id:\.self) { index in
                        Text("\(index+1): [" + value.embeddings[index].prefix(8).map { $0.formatted(.number.precision(.fractionLength(4))) }.joined(separator:", ") + ", …]")
                            .font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    }
                }
            case .transcription(let value):
                output(value.text);copyButton(value.text)
                DisclosureGroup("Timestamped segments") {
                    ForEach(Array(value.segments.enumerated()),id:\.offset) { _,segment in
                        Text("\(segment.start.formatted(.number.precision(.fractionLength(1))))s–\(segment.end.formatted(.number.precision(.fractionLength(1))))s · \(segment.text)").font(.caption).textSelection(.enabled)
                    }
                }
            case .speech(let id):AudioResultPreview(store:store,jobID:id)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func output(_ text:String) -> some View { ScrollView { Text(text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:220) }
    private func copyButton(_ text:String) -> some View { Button("Copy result") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string) } }
}
