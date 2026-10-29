// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacModelAPI", platforms: [.macOS("26.0")],
    products: [.library(name: "ModelAPI", targets: ["ModelAPI"]),
               .executable(name: "MacModelAPI", targets: ["MacModelAPI"])],
    targets: [.target(name: "ModelAPI"), .target(name: "ModelService", dependencies: ["ModelAPI"]),
              .executableTarget(name: "MacModelAPI", dependencies: ["ModelAPI", "ModelService"]),
              .testTarget(name: "ModelAPITests", dependencies: ["ModelAPI", "ModelService"])])
