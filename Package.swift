// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Positronic", platforms: [.macOS("26.0")],
    products: [.library(name: "ModelAPI", targets: ["ModelAPI"]),
               .library(name: "PositronicVoiceDSP", targets: ["CVoiceDSP"]),
               .executable(name: "Positronic", targets: ["Positronic"])],
    targets: [
              .target(name: "CSpeexDSP", path: "ThirdParty/SpeexDSP", exclude: ["COPYING", "NOTICES"], sources: ["libspeexdsp/mdf.c", "libspeexdsp/fftwrap.c", "libspeexdsp/smallft.c", "libspeexdsp/resample.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("libspeexdsp"), .define("HAVE_CONFIG_H")]),
              .target(name: "CRNNoise", path: "ThirdParty/RNNoise", exclude: ["COPYING", "NOTICES"], sources: ["src/denoise.c", "src/rnn.c", "src/rnn_data.c", "src/rnn_reader.c", "src/pitch.c", "src/kiss_fft.c", "src/celt_lpc.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("src"), .define("HAVE_CONFIG_H")]),
              .target(name: "CVoiceDSP", dependencies: ["CSpeexDSP", "CRNNoise"], linkerSettings: [.linkedLibrary("m"), .linkedLibrary("pthread")]),
              .target(name: "ModelAPI"), .target(name: "ModelService", dependencies: ["ModelAPI"]),
              .executableTarget(name: "Positronic", dependencies: ["ModelAPI", "ModelService", "CVoiceDSP"]),
              .testTarget(name: "ModelAPITests", dependencies: ["ModelAPI", "ModelService"]),
              .testTarget(name: "PositronicTests", dependencies: ["Positronic", "ModelAPI", "ModelService", "CVoiceDSP"])])
