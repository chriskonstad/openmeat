import Foundation

public struct EstimatorInput: Sendable, Hashable {
    public var time: Date
    public var probeCelsius: Double
    public var ambientCelsius: Double?

    public init(time: Date, probeCelsius: Double, ambientCelsius: Double? = nil) {
        self.time = time
        self.probeCelsius = probeCelsius
        self.ambientCelsius = ambientCelsius
    }
}

public enum EstimateState: String, Codable, Sendable {
    /// Not enough data yet.
    case warmingUp
    case estimating
    /// Temperature plateau (evaporative stall); ETA is unreliable.
    case stalled
    case reached
    /// No usable trend (cooling, flat outside the stall band, no data).
    case unavailable
}

public enum EstimateMethod: String, Codable, Sendable {
    /// Newton's law of heating with an EWMA-smoothed k.
    case newton
    /// Linear extrapolation of the smoothed rate (no usable ambient).
    case linear
}

public struct Estimate: Codable, Hashable, Sendable {
    public var state: EstimateState
    public var eta: Date?
    public var method: EstimateMethod?
    /// Smoothed rate of change, °C per minute.
    public var celsiusPerMinute: Double?
    /// Smoothed Newton rate constant, 1/s.
    public var k: Double?
    /// 0...1, rough.
    public var confidence: Double

    public init(state: EstimateState, eta: Date? = nil, method: EstimateMethod? = nil,
                celsiusPerMinute: Double? = nil, k: Double? = nil, confidence: Double = 0) {
        self.state = state
        self.eta = eta
        self.method = method
        self.celsiusPerMinute = celsiusPerMinute
        self.k = k
        self.confidence = confidence
    }

    public static let unavailable = Estimate(state: .unavailable)

    public func remaining(from now: Date) -> TimeInterval? {
        eta.map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Pluggable time-to-target estimator. Stateful: feed it readings in time order.
/// See docs/SPEC.md §6. Expect several implementations to be compared via replay tests.
public protocol DoneTimeEstimator: Sendable {
    mutating func ingest(_ input: EstimatorInput)
    func estimate(target: Temperature, now: Date) -> Estimate
    /// Smoothed rate of change in °C/min, available with or without a target.
    var celsiusPerMinute: Double? { get }
}
