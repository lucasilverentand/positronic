import SwiftUI

struct ModelStatusBanner: View {
    @Bindable var store: AppStore
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(store.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { store.message = "" } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss message")
                .accessibilityLabel("Dismiss message")
        }.padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
    }
}
