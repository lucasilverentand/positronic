import Foundation
import FoundationModels
import Security
import ModelAPI

public protocol AppleModelBackend: Sendable {
    func status() async -> ModelInfo
    func cloudStatus(enabled: Bool) async -> ModelInfo
    func generate(_ request: GenerationRequest) async throws -> GenerationResponse
    func generateCloud(_ request: GenerationRequest) async throws -> GenerationResponse
}

/// Read the actual executable's signature; a settings toggle cannot grant an entitlement.
enum AppEntitlements {
    static func allowsPrivateCloudCompute() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.developer.private-cloud-compute"] as? Bool == true
    }
}

extension AppleModel: AppleModelBackend {
    public func cloudStatus(enabled: Bool) -> ModelInfo {
        var result = ModelInfo(id: "apple-pcc", capability: "generation", available: false, detail: "Private Cloud Compute requires macOS 27 and a build made with the macOS 27 SDK.",
                               execution: .applePrivateCloudCompute, reasoningLevels: ReasoningLevel.allCases)
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            guard AppEntitlements.allowsPrivateCloudCompute() else {
                result.detail = "This build needs Apple’s Private Cloud Compute entitlement and an approved provisioning profile."
                return result
            }
            guard enabled else {
                result.detail = "Off. Enable Private Cloud Compute to allow explicitly selected requests to use Apple’s servers."
                return result
            }
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                let quota = model.quotaUsage
                if quota.isLimitReached {
                    result.detail = Self.quotaMessage(resetDate: quota.resetDate)
                } else {
                    result.available = true
                    if case .belowLimit(let usage) = quota.status, usage.isApproachingLimit {
                        result.detail = "Apple Private Cloud Compute is ready. You are nearing Apple’s daily request limit."
                    } else { result.detail = "Apple Private Cloud Compute is ready. Requests use Apple’s servers and daily quota." }
                }
            case .unavailable(.deviceNotEligible): result.detail = "This Mac or region is not eligible for Apple Private Cloud Compute."
            case .unavailable(.systemNotReady): result.detail = "Apple Private Cloud Compute is not ready. Check Apple Intelligence and your internet connection."
            @unknown default: result.detail = "Apple Private Cloud Compute is unavailable."
            }
        }
        #endif
        return result
    }

    public func generateCloud(_ request: GenerationRequest) async throws -> GenerationResponse {
        try request.validate()
        guard request.model == "apple-pcc" else { throw ModelAPIError.invalid("Choose apple-pcc for Private Cloud Compute.") }
        let ready = cloudStatus(enabled: true)
        guard ready.available else { throw ModelAPIError.unavailable(ready.detail) }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            try Task.checkCancellation()
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: request.instructions ?? "Answer the supplied request.")
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maxTokens ?? 600)
            let reasoning: ContextOptions.ReasoningLevel
            switch request.reasoningLevel ?? .moderate {
            case .light: reasoning = .light
            case .moderate: reasoning = .moderate
            case .deep: reasoning = .deep
            }
            let context = ContextOptions(includeSchemaInPrompt: true, reasoningLevel: reasoning)
            do {
                let result: GenerationResponse
                if let schema = request.schema {
                    let converted = try GenerationSchema(root: AppleGenerationSchema.convert(schema, name: "ModelResponse"), dependencies: [])
                    let response = try await session.respond(to: request.prompt, schema: converted, options: options, contextOptions: context)
                    guard response.content.isComplete else { throw ModelAPIError.unavailable("Apple Private Cloud Compute returned an incomplete structure.") }
                    let json = response.content.jsonString
                    result = .init(model: "apple-pcc", text: json, content: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
                } else {
                    let response = try await session.respond(to: request.prompt, options: options, contextOptions: context)
                    result = .init(model: "apple-pcc", text: response.content)
                }
                try Task.checkCancellation()
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ModelAPIError.unavailable("Apple Private Cloud Compute returned no answer. Try a larger response budget.")
                }
                return result
            } catch let error as PrivateCloudComputeLanguageModel.Error { throw Self.cloudFailure(error) }
        }
        #endif
        throw ModelAPIError.unavailable(ready.detail)
    }

    static func quotaMessage(resetDate: Date?) -> String {
        if let resetDate { return "Apple Private Cloud Compute’s daily request limit is reached. Try again after \(resetDate.ISO8601Format())." }
        return "Apple Private Cloud Compute’s daily request limit is reached. Wait for Apple’s quota to reset."
    }
    #if compiler(>=6.4)
    @available(macOS 27.0, *)
    static func cloudFailure(_ error: PrivateCloudComputeLanguageModel.Error) -> ModelAPIError {
        switch error {
        case .networkFailure: .unavailable("Could not connect to Apple Private Cloud Compute. Check your internet connection and retry.")
        case .quotaLimitReached(let quota): .unavailable(quotaMessage(resetDate: quota.resetDate))
        case .serviceUnavailable: .unavailable("Apple Private Cloud Compute is temporarily unavailable. Retry later.")
        @unknown default: .unavailable("Apple Private Cloud Compute is unavailable.")
        }
    }
    #endif
}
