import Foundation

/// Weights plus bounded runtime/activation space and growing duplex KV caches.
/// Admission starts with one small allocation; this estimate still caps monitored RSS.
public enum RealtimeMemoryBudget {
    public static func estimate(weightBytes: Int64, seconds: Int) -> Int64? {
        guard weightBytes > 0, weightBytes <= 64 << 30, (0...600).contains(seconds) else { return nil }
        return weightBytes + (2304 << 20) + Int64(seconds) * (4 << 20)
    }
}
