// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PurpleMatter", platforms: [.macOS("26.0")],
    products: [.library(name: "ModelAPI", targets: ["ModelAPI"]),
               .executable(name: "PurpleMatter", targets: ["PurpleMatter"])],
    targets: [.target(name: "ModelAPI"), .target(name: "ModelService", dependencies: ["ModelAPI"]),
              .executableTarget(name: "PurpleMatter", dependencies: ["ModelAPI", "ModelService"]),
              .testTarget(name: "ModelAPITests", dependencies: ["ModelAPI", "ModelService"])])
