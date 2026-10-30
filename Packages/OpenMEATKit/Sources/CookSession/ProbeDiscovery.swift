import CookCore
import Foundation
import ThermoWorksCloud

/// Guesses a channel's role until we confirm the RFX channel layout (docs/SPEC.md §3.3.1).
/// Users can override the result per channel.
public enum ChannelRoleClassifier {
    public static func role(of channel: TWChannel) -> ProbeRole {
        guard TemperatureUnit(code: channel.units) != nil else { return .unknown }
        let hints = [channel.type, channel.label].compactMap { $0?.lowercased() }
        if hints.contains(where: { $0.contains("ambient") || $0.contains("amb") || $0.contains("pit") }) {
            return .ambient
        }
        return .internal
    }
}

public extension TWChannel {
    var key: ChannelKey { ChannelKey(deviceSerial: ref.deviceSerial, channel: ref.number) }

    /// The reading as a Temperature, or nil for non-temperature channels / missing values.
    var temperature: Temperature? {
        guard let value, let unit = TemperatureUnit(code: units) else { return nil }
        return Temperature(value, unit)
    }
}

public struct DiscoveredDevice: Sendable, Equatable, Identifiable {
    public var id: String { device.serial }
    public var device: TWDevice
    public var channels: [TWChannel]

    public init(device: TWDevice, channels: [TWChannel]) {
        self.device = device
        self.channels = channels
    }
}

public enum ProbeDiscovery {
    /// Lists devices and their channels. Devices whose channels fail to load are returned with none.
    public static func discover(using service: any ThermoWorksService) async throws -> [DiscoveredDevice] {
        let devices = try await service.devices()
        return try await withThrowingTaskGroup(of: DiscoveredDevice.self) { group in
            for device in devices {
                group.addTask {
                    let channels = (try? await service.channels(forDevice: device.serial)) ?? []
                    return DiscoveredDevice(device: device, channels: channels)
                }
            }
            var result: [DiscoveredDevice] = []
            for try await item in group { result.append(item) }
            return result.sorted { ($0.device.label ?? $0.device.serial) < ($1.device.label ?? $1.device.serial) }
        }
    }

    /// Builds cook probes from discovered devices, applying the user's remembered customizations,
    /// then pairing each internal sensor with an ambient sensor and assigning colors.
    public static func probes(from devices: [DiscoveredDevice],
                              customizations: [ChannelKey: ProbeCustomization] = [:]) -> [CookProbe] {
        var probes: [CookProbe] = []
        for discovered in devices {
            let temperatureChannels = discovered.channels.filter { TemperatureUnit(code: $0.units) != nil }
            let roles = Dictionary(uniqueKeysWithValues: temperatureChannels.map {
                ($0.key, customizations[$0.key]?.role ?? ChannelRoleClassifier.role(of: $0))
            })
            let deviceLabel = discovered.device.label ?? discovered.device.serial
            let internalCount = roles.values.filter { $0 == .internal }.count
            for channel in temperatureChannels {
                let role = roles[channel.key] ?? .internal
                let automatic: String = switch role {
                // Wired into the gateway: name the sensor, not the gateway.
                case .ambient where discovered.device.isGateway:
                    temperatureChannels.count > 1 ? "Ambient \(channel.ref.number)" : "Ambient"
                case .ambient: "\(deviceLabel) Ambient"
                case .internal where internalCount > 1: channel.label ?? "\(deviceLabel) \(channel.ref.number)"
                default: deviceLabel
                }
                let custom = customizations[channel.key]?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                probes.append(CookProbe(key: channel.key, label: custom.flatMap { $0.isEmpty ? nil : $0 } ?? automatic, role: role))
            }
        }
        return pairAndColor(probes)
    }

    /// Pairs each internal probe with an ambient sensor (same device first, else any ambient in the cook —
    /// the pit is usually shared) and assigns colors: one per internal probe, in order; an ambient
    /// shares the color of the first internal probe it serves.
    ///
    /// With `preservingColorsOf`, probes keep their existing colors (so a mid-cook role change never
    /// repaints the other series) and only newly-internal probes get a fresh color.
    public static func pairAndColor(_ input: [CookProbe], preservingColorsOf existing: [CookProbe]? = nil) -> [CookProbe] {
        var probes = input
        let ambients = probes.filter { $0.role == .ambient }
        var nextColor = (existing?.map(\.colorIndex).max()).map { $0 + 1 } ?? 0
        for i in probes.indices {
            probes[i].pairedAmbient = nil
            guard probes[i].role == .internal else { continue }
            let serial = probes[i].key.deviceSerial
            probes[i].pairedAmbient = (ambients.first { $0.key.deviceSerial == serial } ?? ambients.first)?.key
            if let previous = existing?.first(where: { $0.key == probes[i].key && $0.role == .internal }) {
                probes[i].colorIndex = previous.colorIndex
            } else {
                probes[i].colorIndex = nextColor
                nextColor += 1
            }
        }
        for i in probes.indices where probes[i].role != .internal {
            let served = probes.first { $0.role == .internal && $0.pairedAmbient == probes[i].key }
            if let served {
                probes[i].colorIndex = served.colorIndex
            } else {
                probes[i].colorIndex = nextColor
                nextColor += 1
            }
        }
        return probes
    }
}

/// A user's remembered choices for one channel (persisted by the app, keyed by `ChannelKey`).
public struct ProbeCustomization: Codable, Hashable, Sendable {
    /// nil = automatic classification.
    public var role: ProbeRole?
    /// nil = automatic name.
    public var label: String?
    /// nil = included by default.
    public var isIncluded: Bool?

    public init(role: ProbeRole? = nil, label: String? = nil, isIncluded: Bool? = nil) {
        self.role = role
        self.label = label
        self.isIncluded = isIncluded
    }
}
