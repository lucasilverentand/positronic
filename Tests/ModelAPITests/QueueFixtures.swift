import Foundation
@testable import ModelAPI
@testable import ModelService

func fixtureQueue() -> JobQueue {
    JobQueue(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PositronicTests/" + UUID().uuidString), interval: .milliseconds(5), probe: {
        .init(physical: 36 * 1024 * 1024 * 1024, available: 32 * 1024 * 1024 * 1024, disk: 100 * 1024 * 1024 * 1024)
    })
}
func fixtureEngine(configuration: ServiceConfiguration, transport: ModelAPIClient.Transport? = nil, activity: ModelActivity? = nil, apple: any AppleModelBackend = AppleModel()) throws -> LocalModelEngine {
    try LocalModelEngine(configuration: configuration, budgetProvider: { _ in 0 }, transport: transport, activity: activity ?? ModelActivity(jobs: fixtureQueue()), apple: apple)
}
func fixtureRouter(keys: APIKeys, engine: any ModelEngine) -> ModelRouter { ModelRouter(keys: keys, engine: engine, jobs: fixtureQueue()) }
