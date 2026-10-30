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

    /// Builds cook probes from discovered devices (docs/SPEC.md §3.2):
    /// - a multi-sensor probe (RFX MEAT) becomes one meat probe whose value is its `computed` core
    ///   channel (the coldest sensor), plus hidden `.sensor` entries for each sensor along the shaft;
    /// - sensors wired into the gateway default to ambient;
    /// - anything else falls back to per-channel classification.
    /// Then remembered customizations are applied and probes are paired with an ambient and colored.
    public static func probes(from devices: [DiscoveredDevice],
                              customizations: [ChannelKey: ProbeCustomization] = [:]) -> [CookProbe] {
        var probes: [CookProbe] = []
        for discovered in devices {
            let device = discovered.device
            let deviceLabel = device.label ?? device.serial
            let temperatureChannels = discovered.channels.filter { TemperatureUnit(code: $0.units) != nil }
            func customLabel(_ key: ChannelKey) -> String? {
                customizations[key]?.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }

            if let core = temperatureChannels.first(where: \.isComputed) {
                let custom = customizations[core.key]
                probes.append(CookProbe(key: core.key, label: customLabel(core.key) ?? deviceLabel,
                                        role: custom?.role ?? .internal, showsSensors: custom?.showsSensors ?? false))
                for (index, sensor) in temperatureChannels.filter(\.isProbeSensor).enumerated() {
                    probes.append(CookProbe(key: sensor.key, label: sensor.label ?? "Sensor \(index + 1)",
                                            role: .sensor, parent: core.key))
                }
                continue
            }

            let roles = Dictionary(uniqueKeysWithValues: temperatureChannels.map { channel in
                let automatic: ProbeRole = device.isGateway ? .ambient : ChannelRoleClassifier.role(of: channel)
                return (channel.key, customizations[channel.key]?.role ?? automatic)
            })
            let internalCount = roles.values.filter { $0 == .internal }.count
            for channel in temperatureChannels {
                let role = roles[channel.key] ?? .internal
                let numbered = temperatureChannels.count > 1
                let automatic: String = switch role {
                // Wired into the gateway: name the sensor, not the gateway.
                case .ambient where device.isGateway: numbered ? "Ambient \(channel.ref.number)" : "Ambient"
                case .internal where device.isGateway: "Probe \(channel.ref.number)"
                case .ambient: "\(deviceLabel) Ambient"
                case .internal where internalCount > 1: channel.label ?? "\(deviceLabel) \(channel.ref.number)"
                default: deviceLabel
                }
                probes.append(CookProbe(key: channel.key, label: customLabel(channel.key) ?? automatic, role: role))
            }
        }
        return pairAndColor(probes)
    }

    /// Pairs each meat probe with an ambient sensor (same device first, else any ambient in the cook —
    /// the pit is usually shared) and assigns colors: one per meat probe, in order. Sensors share their
    /// probe's color. An ambient takes its probe's color only if it serves exactly one probe; one
    /// shared by several probes (e.g. wired into the gateway) is neutral.
    ///
    /// With `preservingColorsOf`, probes keep their existing colors (so a mid-cook role change never
    /// repaints the other series) and only newly-internal probes get a fresh color.
    public static func pairAndColor(_ input: [CookProbe], preservingColorsOf existing: [CookProbe]? = nil) -> [CookProbe] {
        var probes = input
        let ambients = probes.filter { $0.role == .ambient }
        var nextColor = (existing?.map(\.colorIndex).max()).map { max($0 + 1, 0) } ?? 0
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
            if probes[i].role == .sensor, let parent = probes[i].parent,
               let owner = probes.first(where: { $0.key == parent }) {
                probes[i].colorIndex = owner.colorIndex
                continue
            }
            let served = probes.filter { $0.role == .internal && $0.pairedAmbient == probes[i].key }
            if served.count == 1 {
                probes[i].colorIndex = served[0].colorIndex
            } else if !served.isEmpty || probes[i].role == .ambient {
                probes[i].colorIndex = CookProbe.neutralColor
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
    /// Multi-sensor probes: show every sensor, not just the core. nil = off.
    public var showsSensors: Bool?

    public init(role: ProbeRole? = nil, label: String? = nil, isIncluded: Bool? = nil, showsSensors: Bool? = nil) {
        self.role = role
        self.label = label
        self.isIncluded = isIncluded
        self.showsSensors = showsSensors
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
