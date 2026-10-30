import Foundation

/// Tuning knobs. Provisional defaults — expected to change after real-cook replay testing.
public struct EstimatorConfiguration: Sendable, Hashable, Codable {
    /// Trailing window for the least-squares slope.
    public var slopeWindow: TimeInterval = 5 * 60
    /// Half-life of the time-aware EWMA applied to k, the rate, and ambient.
    public var halfLife: TimeInterval = 10 * 60
    /// Minimum data span before producing an ETA.
    public var warmup: TimeInterval = 10 * 60
    /// Skip k updates when ambient − probe is smaller than this (ill-conditioned).
    public var minAmbientGapCelsius: Double = 5
    /// Probe band where evaporative stalls happen (~140–170 °F).
    public var stallBandCelsius: ClosedRange<Double> = 60...77
    /// |rate| below this inside the band counts as stalled.
    public var stallRateCelsiusPerMinute: Double = 0.05

    public init() {}
}

/// Newton's law of heating, dT/dt = k·(Ta − T), with k smoothed by a time-aware EWMA.
///
/// - k_inst = slope / mean(Ta − T) over a trailing window (least-squares slope).
/// - k ← α·k_inst + (1 − α)·k, α = 1 − exp(−Δt·ln2 / halfLife).
/// - ETA = ln((Ta − T) / (Ta − target)) / k when Ta > target, else linear fallback.
public struct NewtonEWMAEstimator: DoneTimeEstimator {
    public var configuration: EstimatorConfiguration

    private var window: [EstimatorInput] = []
    private var firstTime: Date?
    private var lastUpdate: Date?
    public private(set) var smoothedK: Double?
    /// °C per second.
    public private(set) var smoothedRate: Double?
    public private(set) var smoothedAmbient: Double?
    private var latest: EstimatorInput?

    public var celsiusPerMinute: Double? { smoothedRate.map { $0 * 60 } }

    public init(configuration: EstimatorConfiguration = EstimatorConfiguration()) {
        self.configuration = configuration
    }

    public mutating func ingest(_ input: EstimatorInput) {
        if let latest, input.time <= latest.time { return }
        firstTime = firstTime ?? input.time
        latest = input
        window.append(input)
        // Trim to the slope window, but always keep two points so sparse data (gaps after the app was
        // suspended, slow transmit intervals) still yields a slope.
        while window.count > 2, let oldest = window.first, input.time.timeIntervalSince(oldest.time) > configuration.slopeWindow {
            window.removeFirst()
        }

        let dt = lastUpdate.map { input.time.timeIntervalSince($0) } ?? 0
        let alpha = dt > 0 ? 1 - exp(-dt * M_LN2 / configuration.halfLife) : 1

        if let ambient = input.ambientCelsius {
            smoothedAmbient = Self.blend(smoothedAmbient, ambient, alpha)
        }

        // Need at least half a window of data for a meaningful slope.
        guard let first = window.first, input.time.timeIntervalSince(first.time) >= configuration.slopeWindow / 2,
              let slope = Self.leastSquaresSlope(window) else { return }

        smoothedRate = Self.blend(smoothedRate, slope, alpha)

        let gaps = window.compactMap { s in s.ambientCelsius.map { $0 - s.probeCelsius } }
        if gaps.count == window.count {
            let meanGap = gaps.reduce(0, +) / Double(gaps.count)
            if meanGap >= configuration.minAmbientGapCelsius {
                smoothedK = Self.blend(smoothedK, slope / meanGap, alpha)
            }
        }
        lastUpdate = input.time
    }

    public func estimate(target: Temperature, now: Date) -> Estimate {
        guard let latest, let firstTime else { return .unavailable }
        let probe = latest.probeCelsius
        let ratePerMinute = smoothedRate.map { $0 * 60 }

        if probe >= target.celsius {
            return Estimate(state: .reached, eta: latest.time, celsiusPerMinute: ratePerMinute, k: smoothedK, confidence: 1)
        }
        let span = latest.time.timeIntervalSince(firstTime)
        guard span >= configuration.warmup, let rate = smoothedRate else {
            return Estimate(state: .warmingUp, celsiusPerMinute: ratePerMinute, k: smoothedK)
        }
        if configuration.stallBandCelsius.contains(probe), abs(rate * 60) < configuration.stallRateCelsiusPerMinute {
            return Estimate(state: .stalled, celsiusPerMinute: rate * 60, k: smoothedK, confidence: 0.2)
        }
        // Readings may lag "now" (polling, background); measure from the last reading.
        let confidence = min(1, span / (configuration.warmup * 4))

        if let k = smoothedK, k > 0, let ambient = smoothedAmbient,
           ambient - target.celsius >= configuration.minAmbientGapCelsius / 2, ambient > probe {
            let remaining = log((ambient - probe) / (ambient - target.celsius)) / k
            if remaining.isFinite, remaining >= 0 {
                return Estimate(state: .estimating, eta: latest.time.addingTimeInterval(remaining), method: .newton,
                                celsiusPerMinute: rate * 60, k: k, confidence: confidence)
            }
        }
        if rate > 0 {
            let remaining = (target.celsius - probe) / rate
            return Estimate(state: .estimating, eta: latest.time.addingTimeInterval(remaining), method: .linear,
                            celsiusPerMinute: rate * 60, k: smoothedK, confidence: confidence * 0.5)
        }
        return Estimate(state: .unavailable, celsiusPerMinute: rate * 60, k: smoothedK)
    }

    // MARK: Math

    static func blend(_ previous: Double?, _ value: Double, _ alpha: Double) -> Double {
        guard let previous else { return value }
        return alpha * value + (1 - alpha) * previous
    }

    /// Slope of probe temperature vs. time, °C per second.
    static func leastSquaresSlope(_ points: [EstimatorInput]) -> Double? {
        guard points.count >= 2, let t0 = points.first?.time else { return nil }
        let xs = points.map { $0.time.timeIntervalSince(t0) }
        let ys = points.map(\.probeCelsius)
        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - meanX) * (y - meanY)
            den += (x - meanX) * (x - meanX)
        }
        return den > 0 ? num / den : nil
    }
}
