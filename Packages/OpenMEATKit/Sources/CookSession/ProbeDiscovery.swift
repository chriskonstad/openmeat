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

    /// Builds cook probes from discovered devices, pairing each internal sensor with its device's ambient sensor.
    public static func probes(from devices: [DiscoveredDevice]) -> [CookProbe] {
        var probes: [CookProbe] = []
        for discovered in devices {
            let temperatureChannels = discovered.channels.filter { TemperatureUnit(code: $0.units) != nil }
            let ambient = temperatureChannels.first { ChannelRoleClassifier.role(of: $0) == .ambient }
            let deviceLabel = discovered.device.label ?? discovered.device.serial
            let internalCount = temperatureChannels.filter { ChannelRoleClassifier.role(of: $0) == .internal }.count
            for channel in temperatureChannels {
                let role = ChannelRoleClassifier.role(of: channel)
                let label: String
                switch role {
                case .ambient: label = "\(deviceLabel) Ambient"
                case .internal where internalCount > 1: label = channel.label ?? "\(deviceLabel) \(channel.ref.number)"
                default: label = deviceLabel
                }
                probes.append(CookProbe(
                    key: channel.key, label: label, role: role,
                    pairedAmbient: role == .internal ? ambient?.key : nil,
                    colorIndex: probes.count))
            }
        }
        return probes
    }
}
