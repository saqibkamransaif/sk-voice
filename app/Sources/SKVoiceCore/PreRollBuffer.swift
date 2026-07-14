import Foundation

/// Fixed-capacity rolling buffer of the most recent mic samples. The engine runs
/// continuously, so we can keep the last ~0.6 s around and prepend it when a capture
/// starts — recovering the syllables spoken a beat before the hotkey landed.
public struct PreRollBuffer: Sendable {
    private var samples: [Float] = []
    private let capacity: Int

    public init(seconds: Double = 0.6, sampleRate: Double = 16_000) {
        capacity = max(0, Int(seconds * sampleRate))
    }

    public mutating func append(_ chunk: [Float]) {
        guard capacity > 0 else { return }
        samples.append(contentsOf: chunk)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Drains the buffered pre-roll (returns it and clears).
    public mutating func drain() -> [Float] {
        let drained = samples
        samples = []
        return drained
    }

    public var count: Int { samples.count }
}
