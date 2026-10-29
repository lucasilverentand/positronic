import Foundation

public enum ModelAPIError: Error, LocalizedError, Sendable {
    case invalid(String), unavailable(String), limit(String), unauthorized
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message), .limit(let message): message
        case .unauthorized: "API key required."
        }
    }
}
