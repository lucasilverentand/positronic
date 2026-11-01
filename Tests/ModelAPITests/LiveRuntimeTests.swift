import Foundation
import XCTest
import ModelAPI
import ModelService

final class LiveRuntimeTests: XCTestCase, @unchecked Sendable {
    func testNativeDownloaderWhileAuthenticatedAPIStaysAvailable() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PURPLE_MATTER_LIVE"] == "1", let keyPath = environment["PURPLE_MATTER_KEY_FILE"] else {
            throw XCTSkip("Explicit local runtime and private client key required")
        }
        let library = try ModelLibrary(configuration: .init())
        let before = try await library.installed()
        let preset = try XCTUnwrap(ModelLibrary.presets.first { $0.id == "qwen3.5:4b" })
        XCTAssertTrue(before.contains { $0.id == preset.id })
        // A cached pull exercises the production progress parser without another weight download.
        try await library.download(preset) { _ in }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try ModelAPIClient(baseURL: URL(string: "http://127.0.0.1:18767")!, apiKey: key)
        let models = try await client.models()
        XCTAssertTrue(models.contains { $0.id == preset.id && $0.available })
    }
}
