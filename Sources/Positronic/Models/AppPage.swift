import Foundation

enum AppPage: String, CaseIterable, Identifiable {
    case models, discover, playground, api, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .models: "Your models"
        case .discover: "Discover"
        case .playground: "Playground"
        case .api: "API & Keys"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .models: "square.stack.3d.up"
        case .discover: "square.grid.2x2"
        case .playground: "text.bubble"
        case .api: "network"
        case .settings: "gearshape"
        }
    }
}
