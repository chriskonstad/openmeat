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

        public var needsAttention: Bool {
            switch self {
            case .low, .critical: true
            case .none, .ok: false
            }
        }
    }

    public static let lowThreshold = 20
    public static let criticalThreshold = 10

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

    public init(serial: String, label: String, isGateway: Bool, batteryPercent: Int?, batteryState: String?,
                signalStrength: Int?, lastSeen: Date?) {
        self.serial = serial
        self.label = label
        self.isGateway = isGateway
        self.batteryPercent = batteryPercent
        self.batteryState = batteryState
        self.signalStrength = signalStrength
        self.lastSeen = lastSeen
    }

    public init(device: TWDevice) {
        self.init(serial: device.serial, label: device.label ?? device.serial, isGateway: device.isGateway,
                  batteryPercent: device.battery.map { min(max($0, 0), 100) }, batteryState: device.batteryState,
                  signalStrength: device.signalStrength, lastSeen: device.lastSeen)
    }

    public var battery: BatteryLevel {
        let state = batteryState?.uppercased() ?? ""
        if state.contains("CRIT") || state.contains("DEAD") || state.contains("EMPTY") { return .critical(percent: batteryPercent) }
        guard let percent = batteryPercent else {
            if state.contains("LOW") { return .low(percent: nil) }
            return state.isEmpty ? .none : .ok(percent: nil)
        }
        if percent <= Self.criticalThreshold { return .critical(percent: percent) }
        if percent <= Self.lowThreshold || state.contains("LOW") { return .low(percent: percent) }
        return .ok(percent: percent)
    }
}

public extension DiscoveredDevice {
    var health: DeviceHealth { DeviceHealth(device: device) }
}
