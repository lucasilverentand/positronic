import Foundation
import ModelAPI

public actor ModelRouter {
    private let keys: APIKeys
    private let engine: any ModelEngine
    private var active = 0
    public init(keys: APIKeys, engine: any ModelEngine) { self.keys = keys; self.engine = engine }
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // The service is for API clients. Browser origins are intentionally unsupported.
        guard request.headers["origin"] == nil, await keys.accepts(request.bearer) else { return .error("API key required.", status: 401) }
        guard active < 4 else { return .error("The Mac is busy. Try again later.", status: 429) }
        active += 1; defer { active -= 1 }
        do {
            if request.method == "GET", request.path == "/v1/models" { return try .json(await engine.models()) }
            guard request.method == "POST" else { return .error("Endpoint not found.", status: 404) }
            guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { return .error("Use application/json.", status: 415) }
            switch request.path {
            case "/v1/generate": return try .json(await engine.generate(JSONDecoder().decode(GenerationRequest.self, from: request.body)))
            case "/v1/decisions", "/v1/systemone": return try .json(await engine.decide(JSONDecoder().decode(DecisionRequest.self, from: request.body)))
            default: return .error("Endpoint not found.", status: 404)
            }
        } catch let error as ModelAPIError {
            let status: Int
            switch error { case .invalid: status = 400; case .limit: status = 413; case .unauthorized: status = 401; case .unavailable: status = 503 }
            return .error(error.localizedDescription, status: status)
        } catch is DecodingError { return .error("Invalid JSON request or model response.", status: 400) }
        catch { return .error("Model request failed. Check local model availability and context size.", status: 503) }
    }
}
