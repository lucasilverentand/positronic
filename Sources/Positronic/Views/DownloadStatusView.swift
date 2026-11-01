import SwiftUI

struct DownloadStatusView: View {
    @Bindable var store: AppStore
    var body: some View {
        if let model = store.downloading {
            HStack(spacing: 18) {
                Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Downloading \(model.name)").font(.callout.weight(.medium))
                    Text(store.downloadProgress?.status ?? "Connecting to the runtime…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let fraction = store.downloadProgress?.fraction {
                    ProgressView(value: fraction).frame(width: 120)
                    Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Button("Cancel") { store.cancelDownload() }
            }.padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
        }
    }
}
