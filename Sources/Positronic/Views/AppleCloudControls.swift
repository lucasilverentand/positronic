import SwiftUI
import ModelAPI

struct AppleCloudControls: View {
    @Bindable var store: AppStore
    let info: ModelInfo?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reasoning for more complex requests, with light, moderate and deep effort levels.").font(.callout).foregroundStyle(.secondary)
            Toggle("Allow Private Cloud Compute", isOn: Binding(
                get: { store.configuration.allowApplePCC },
                set: { enabled in Task { await store.setApplePCC(enabled) } }
            )).toggleStyle(.switch).disabled(store.managingModels)
            Text(info?.detail ?? "Checking Private Cloud Compute…").font(.callout).foregroundStyle(.secondary)
            Text("Model tests and API clients must select this model explicitly. Requests use Apple’s servers and daily quota. Positronic never upgrades your plan automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Apple access requirements", destination: URL(string: "https://developer.apple.com/private-cloud-compute/")!)
        }
    }
}
