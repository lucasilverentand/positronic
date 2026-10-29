// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Positronic", platforms: [.macOS("26.0")],
    products: [.library(name: "ModelAPI", targets: ["ModelAPI"]),
               .executable(name: "Positronic", targets: ["Positronic"])],
    targets: [.target(name: "ModelAPI"), .target(name: "ModelService", dependencies: ["ModelAPI"]),
              .executableTarget(name: "Positronic", dependencies: ["ModelAPI", "ModelService"]),
              .testTarget(name: "ModelAPITests", dependencies: ["ModelAPI", "ModelService"])])
