import CookCore
import Foundation

/// Deterministic cook physics for demo mode and tests.
/// Probe temperature follows dT/dt = k·(Ta − T), with k reduced inside a stall band
/// (evaporative cooling), plus small seeded sensor noise.
public struct CookSimulator: Sendable {
    public struct Stall: Sendable, Hashable {
        public var bandCelsius: ClosedRange<Double>
        /// k multiplier inside the band (0.1 = 10× slower).
        public var factor: Double

        public init(bandCelsius: ClosedRange<Double> = 65...72, factor: Double = 0.12) {
            self.bandCelsius = bandCelsius
            self.factor = factor
        }
    }

    public enum AmbientProfile: Sendable, Hashable {
        case steady(celsius: Double)
        /// Heats from `start` to `celsius` over `rampSeconds`, with a gentle wobble.
        case ramp(start: Double, celsius: Double, rampSeconds: TimeInterval)
        /// Steady with brief lid-open dips every `interval` seconds.
        case lidOpenings(celsius: Double, interval: TimeInterval, dipCelsius: Double)

        func value(at t: TimeInterval) -> Double {
            switch self {
            case .steady(let c):
                return c + 1.5 * sin(t / 900)
            case .ramp(let start, let c, let ramp):
                let base = t >= ramp ? c : start + (c - start) * (t / ramp)
                return base + 1.5 * sin(t / 900)
            case .lidOpenings(let c, let interval, let dip):
                let phase = t.truncatingRemainder(dividingBy: interval)
                // 3-minute dip that recovers exponentially.
                return phase < 180 ? c - dip * exp(-phase / 60) : c
            }
        }
    }

    public struct Channel: Sendable, Hashable {
        public var number: String
        public var role: ProbeRole
        public var label: String?
        public var startCelsius: Double
        /// Newton rate constant, 1/s (internal channels only).
        public var k: Double
        public var stall: Stall?
        /// Seconds after start when this channel stops reporting (dropout scenario).
        public var dropsOutAfter: TimeInterval?

        public init(number: String, role: ProbeRole, label: String? = nil, startCelsius: Double = 4,
                    k: Double = 0.00012, stall: Stall? = nil, dropsOutAfter: TimeInterval? = nil) {
            self.number = number
            self.role = role
            self.label = label
            self.startCelsius = startCelsius
            self.k = k
            self.stall = stall
            self.dropsOutAfter = dropsOutAfter
        }
    }

    /// A simulated device: a wireless probe, or the gateway (whose ambient channels are wired).
    public struct Probe: Sendable, Hashable {
        public var serial: String
        public var label: String
        public var ambient: AmbientProfile
        public var channels: [Channel]
        public var isGateway: Bool
        /// Battery percent at the start of the cook; nil = no battery reported.
        public var battery: Int?
        /// Percentage points lost per hour of simulated time.
        public var batteryDrainPerHour: Double

        public init(serial: String, label: String, ambient: AmbientProfile, channels: [Channel],
                    isGateway: Bool = false, battery: Int? = 87, batteryDrainPerHour: Double = 0) {
            self.serial = serial
            self.label = label
            self.ambient = ambient
            self.channels = channels
            self.isGateway = isGateway
            self.battery = battery
            self.batteryDrainPerHour = batteryDrainPerHour
        }

        public func battery(at elapsed: TimeInterval) -> Int? {
            battery.map { max(0, Int((Double($0) - batteryDrainPerHour * elapsed / 3600).rounded(.down))) }
        }
    }

    public var probes: [Probe]
    public var seed: UInt64
    public var noiseCelsius: Double
    /// Integration step.
    public var step: TimeInterval = 5

    public init(probes: [Probe], seed: UInt64 = 42, noiseCelsius: Double = 0.08) {
        self.probes = probes
        self.seed = seed
        self.noiseCelsius = noiseCelsius
    }

    /// Temperature in °C of a channel at `elapsed` seconds since the cook started, or nil if dropped out.
    public func celsius(serial: String, channel number: String, at elapsed: TimeInterval) -> Double? {
        guard let probe = probes.first(where: { $0.serial == serial }),
              let channel = probe.channels.first(where: { $0.number == number }) else { return nil }
        if let dropout = channel.dropsOutAfter, elapsed > dropout { return nil }
        let t = max(0, elapsed)
        let clean: Double
        switch channel.role {
        case .ambient, .unknown:
            clean = probe.ambient.value(at: t)
        case .internal:
            clean = integrate(channel, ambient: probe.ambient, until: t)
        }
        return clean + noise(serial: serial, channel: number, bucket: Int(t / 15))
    }

    private func integrate(_ channel: Channel, ambient: AmbientProfile, until t: TimeInterval) -> Double {
        var temp = channel.startCelsius
        var time = 0.0
        while time < t {
            let dt = min(step, t - time)
            var k = channel.k
            if let stall = channel.stall, stall.bandCelsius.contains(temp) { k *= stall.factor }
            temp += k * (ambient.value(at: time) - temp) * dt
            time += dt
        }
        return temp
    }

    private func noise(serial: String, channel: String, bucket: Int) -> Double {
        var hasher = StableHasher(seed: seed)
        hasher.combine(serial)
        hasher.combine(channel)
        hasher.combine(UInt64(bitPattern: Int64(bucket)))
        // Map to [-1, 1).
        let unit = Double(hasher.value >> 11) / Double(1 << 53)
        return (unit * 2 - 1) * noiseCelsius
    }
}

/// SplitMix64-based hashing (Swift's Hasher is randomly seeded per process, so not reproducible).
struct StableHasher {
    private(set) var value: UInt64

    init(seed: UInt64) { value = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func combine(_ x: UInt64) {
        value ^= x &+ 0x9E37_79B9_7F4A_7C15 &+ (value << 6) &+ (value >> 2)
        value = Self.mix(value)
    }

    mutating func combine(_ s: String) {
        for byte in s.utf8 { combine(UInt64(byte)) }
    }

    static func mix(_ z0: UInt64) -> UInt64 {
        var z = z0
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
