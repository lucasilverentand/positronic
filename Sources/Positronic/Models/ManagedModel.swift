import Foundation
import ModelAPI
import ModelService

struct ManagedModel: Identifiable {
    enum Location { case appleDevice, appleCloud, downloaded }
    let id: String
    let title: String
    let location: Location
    let capability: ModelCapability?
    let installed: InstalledModel?
    let info: ModelInfo?
    var symbol: String {
        switch location { case .appleDevice: "apple.logo"; case .appleCloud: "cloud"; case .downloaded: "cpu" }
    }
    var locationTitle: String { location == .appleCloud ? "Apple’s servers" : "On this Mac" }
    var matchesSearch: String { "\(title) \(id) \(capability?.title ?? "") \(locationTitle)" }
    @MainActor static func all(in store: AppStore) -> [Self] {
        let apple = store.models.filter { ["apple", "apple-pcc"].contains($0.id) }.map { info in
            Self(id: info.id, title: info.id == "apple" ? "Apple Intelligence" : "Private Cloud Compute",
                 location: info.id == "apple" ? .appleDevice : .appleCloud, capability: .generation, installed: nil, info: info)
        }
        let downloaded = store.installedModels.map { model in
            Self(id: model.id, title: ModelLibrary.presets.first { $0.id == model.id }?.name ?? model.id,
                 location: .downloaded, capability: model.capability, installed: model, info: nil)
        }
        return apple + downloaded
    }
}
