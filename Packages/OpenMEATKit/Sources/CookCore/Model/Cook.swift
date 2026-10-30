import Foundation

/// Identifies one sensor across the app: device serial + channel number.
public struct ChannelKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible, CodingKeyRepresentable {
    public var deviceSerial: String
    public var channel: String

    public init(deviceSerial: String, channel: String) {
        self.deviceSerial = deviceSerial
        self.channel = channel
    }

    public var description: String { "\(deviceSerial)#\(channel)" }

    public static func < (lhs: ChannelKey, rhs: ChannelKey) -> Bool {
        (lhs.deviceSerial, lhs.channel) < (rhs.deviceSerial, rhs.channel)
    }

    // Encode dictionaries keyed by ChannelKey as JSON objects ("serial#1": [...]).
    public var codingKey: any CodingKey { StringKey(description) }

    public init?<T: CodingKey>(codingKey: T) {
        let parts = codingKey.stringValue.split(separator: "#", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.init(deviceSerial: String(parts[0]), channel: String(parts[1]))
    }

    private struct StringKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public enum ProbeRole: String, Codable, Sendable, CaseIterable {
    /// Inside the meat — can have a target and an ETA. For a multi-sensor probe (RFX MEAT) this is
    /// its core reading: the coldest sensor, which ThermoWorks reports as a "computed" channel.
    case `internal`
    /// Cooker / pit air temperature.
    case ambient
    /// One sensor along a multi-sensor probe's shaft. Shown only when the probe's "show all
    /// sensors" is on; never has a target.
    case sensor
    case unknown
}

public struct Sample: Codable, Hashable, Sendable {
    public var time: Date
    public var celsius: Double

    public init(time: Date, celsius: Double) {
        self.time = time
        self.celsius = celsius
    }

    public var temperature: Temperature { Temperature(celsius: celsius) }
}

/// A channel participating in a cook.
public struct CookProbe: Codable, Hashable, Sendable, Identifiable {
    public var id: ChannelKey { key }
    public var key: ChannelKey
    public var label: String
    public var role: ProbeRole
    public var target: Temperature?
    /// Ambient channel used for this probe's ETA (e.g. the ambient sensor wired into the gateway).
    public var pairedAmbient: ChannelKey?
    /// Stable index into the chart palette; `ProbePalette.neutral` for an ambient shared by several probes.
    public var colorIndex: Int
    /// For `.sensor`: the core channel of the probe it belongs to.
    public var parent: ChannelKey?
    /// For a multi-sensor probe's core: show its individual sensors on cards and the chart.
    public var showsSensors: Bool

    public static let neutralColor = -1

    public init(key: ChannelKey, label: String, role: ProbeRole, target: Temperature? = nil,
                pairedAmbient: ChannelKey? = nil, colorIndex: Int = 0, parent: ChannelKey? = nil,
                showsSensors: Bool = false) {
        self.key = key
        self.label = label
        self.role = role
        self.target = target
        self.pairedAmbient = pairedAmbient
        self.colorIndex = colorIndex
        self.parent = parent
        self.showsSensors = showsSensors
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, role, target, pairedAmbient, colorIndex, parent, showsSensors
    }

    // Cooks saved before sensors existed lack `parent` / `showsSensors`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(ChannelKey.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        role = try c.decode(ProbeRole.self, forKey: .role)
        target = try c.decodeIfPresent(Temperature.self, forKey: .target)
        pairedAmbient = try c.decodeIfPresent(ChannelKey.self, forKey: .pairedAmbient)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        parent = try c.decodeIfPresent(ChannelKey.self, forKey: .parent)
        showsSensors = try c.decodeIfPresent(Bool.self, forKey: .showsSensors) ?? false
    }
}

public struct CookNote: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var time: Date
    public var text: String
    /// True when created from a quick-note chip (e.g. "Wrapped").
    public var isQuickNote: Bool

    public init(id: UUID = UUID(), time: Date, text: String, isQuickNote: Bool = false) {
        self.id = id
        self.time = time
        self.text = text
        self.isQuickNote = isQuickNote
    }
}

public struct Cook: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var probes: [CookProbe]
    public var notes: [CookNote]
    public var series: [ChannelKey: [Sample]]
    /// Per-cook override of the "almost done" lead time; nil = app default.
    public var almostDoneLeadTime: TimeInterval?

    public init(id: UUID = UUID(), title: String, startedAt: Date, endedAt: Date? = nil,
                probes: [CookProbe] = [], notes: [CookNote] = [], series: [ChannelKey: [Sample]] = [:],
                almostDoneLeadTime: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.probes = probes
        self.notes = notes
        self.series = series
        self.almostDoneLeadTime = almostDoneLeadTime
    }

    public var isActive: Bool { endedAt == nil }

    public func probe(_ key: ChannelKey) -> CookProbe? { probes.first { $0.key == key } }

    /// When a probe first read at or above its target (for "time since target"), or nil.
    public func targetReachedAt(_ key: ChannelKey) -> Date? {
        guard let target = probe(key)?.target else { return nil }
        return series[key]?.first { $0.celsius >= target.celsius }?.time
    }

    /// The individual sensors of a multi-sensor probe, in channel order.
    public func sensors(of key: ChannelKey) -> [CookProbe] {
        probes.filter { $0.parent == key }
    }

    /// Probes whose lines/values are shown: everything except sensors of probes that hide them.
    public var visibleProbes: [CookProbe] {
        probes.filter { probe in
            guard probe.role == .sensor else { return true }
            return probe.parent.flatMap { self.probe($0) }?.showsSensors ?? false
        }
    }

    public func latestSample(_ key: ChannelKey) -> Sample? { series[key]?.last }

    public func duration(asOf now: Date) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }

    /// Appends keeping each series time-ordered; ignores samples not newer than the last one.
    @discardableResult
    public mutating func append(_ sample: Sample, to key: ChannelKey) -> Bool {
        if let last = series[key]?.last, sample.time <= last.time { return false }
        series[key, default: []].append(sample)
        return true
    }
}
