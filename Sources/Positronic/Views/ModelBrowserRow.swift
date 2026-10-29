import SwiftUI

struct ModelBrowserRow: View {
    @Bindable var store: AppStore
    let model: ManagedModel
    private var status: String {
        if let installed = model.installed {
            guard store.loadedStatusKnown else { return "Unknown" }
            return store.loadedModel(installed) == nil ? "On disk" : "Loaded"
        }
        if model.location == .appleCloud && !store.configuration.allowApplePCC { return "Off" }
        return model.info?.available == true ? "Ready" : "Unavailable"
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(model.capability?.title ?? "Unknown type") · \(model.locationTitle)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.modelOperation == model.id { ProgressView().controlSize(.small) }
            else { Text(status).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 9)
    }
}
