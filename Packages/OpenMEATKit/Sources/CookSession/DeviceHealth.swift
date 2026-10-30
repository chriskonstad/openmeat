import Foundation
import ThermoWorksCloud

/// Battery/connection status for one device (a wireless probe or the gateway). Batteries belong
/// to devices, not sensors: an ambient sensor wired into the gateway has no battery of its own.
public struct DeviceHealth: Sendable, Equatable, Identifiable {
    public enum BatteryLevel: Sendable, Equatable {
        /// The device doesn't report a battery (mains/USB powered, or not exposed).
        case none
        case ok(percent: Int?)
        case low(percent: Int?)
        case critical(percent: Int?)

        public var percent: Int? {
            switch self {
            case .none: nil
            case .ok(let p), .low(let p), .critical(let p): p
            }
        }

        /// Worth a warning banner: critical only (low is shown, not announced).
        public var needsAttention: Bool {
            if case .critical = self { return true }
            return false
        }
    }

    public enum Connection: Sendable, Equatable {
        case online
        /// Not heard from recently (asleep, charging, out of range, gateway offline).
        case offline(lastSeen: Date?)
    }

    public enum SignalQuality: Int, Sendable, Comparable {
        case weak = 1, fair, strong
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Below this percent: "low" (yellow-orange).
    public static let lowThreshold = 50
    /// Below this percent: "critical" (red).
    public static let criticalThreshold = 20

    public var id: String { serial }
    public var serial: String
    public var label: String
    public var isGateway: Bool
    public var batteryPercent: Int?
    /// Raw state string from ThermoWorks (e.g. "NORMAL", "LOW"); used when it reports trouble.
    public var batteryState: String?
    /// dBm (gateway RSSI for probes, Wi-Fi for the gateway).
    public var signalStrength: Int?
    public var lastSeen: Date?
    /// How often the device reports; drives the online/offline cutoff.
    public var transmitInterval: TimeInterval?

    public init(serial: String, label: String, isGateway: Bool, batteryPercent: Int?, batteryState: String?,
                signalStrength: Int?, lastSeen: Date?, transmitInterval: TimeInterval? = nil) {
        self.serial = serial
        self.label = label
        self.isGateway = isGateway
        self.batteryPercent = batteryPercent
        self.batteryState = batteryState
        self.signalStrength = signalStrength
        self.lastSeen = lastSeen
        self.transmitInterval = transmitInterval
    }

    public init(device: TWDevice) {
        self.init(serial: device.serial, label: device.label ?? device.serial, isGateway: device.isGateway,
                  batteryPercent: device.battery.map { min(max($0, 0), 100) }, batteryState: device.batteryState,
                  signalStrength: device.signalStrength, lastSeen: device.lastSeen,
                  transmitInterval: device.transmitInterval)
    }

    public var battery: BatteryLevel {
        let state = batteryState?.uppercased() ?? ""
        if state.contains("CRIT") || state.contains("DEAD") || state.contains("EMPTY") { return .critical(percent: batteryPercent) }
        guard let percent = batteryPercent else {
            if state.contains("LOW") { return .low(percent: nil) }
            return state.isEmpty ? .none : .ok(percent: nil)
        }
        if percent < Self.criticalThreshold { return .critical(percent: percent) }
        if percent < Self.lowThreshold || state.contains("LOW") { return .low(percent: percent) }
        return .ok(percent: percent)
    }

    /// Online if heard from within three report intervals (at least 3 minutes).
    public func connection(now: Date) -> Connection {
        guard let lastSeen else { return .offline(lastSeen: nil) }
        let cutoff = max(3 * (transmitInterval ?? 60), 180)
        return now.timeIntervalSince(lastSeen) <= cutoff ? .online : .offline(lastSeen: lastSeen)
    }

    /// From RSSI in dBm: the probe→gateway radio link, or the gateway's Wi-Fi.
    public var signal: SignalQuality? {
        guard let dbm = signalStrength else { return nil }
        if dbm >= -60 { return .strong }
        if dbm >= -75 { return .fair }
        return .weak
    }
}

public extension DiscoveredDevice {
    var health: DeviceHealth { DeviceHealth(device: device) }
}
