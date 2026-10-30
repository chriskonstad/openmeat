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
    /// Inside the meat — can have a target and an ETA.
    case `internal`
    /// Cooker / pit air temperature.
    case ambient
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
    /// Ambient channel used for this probe's ETA, typically the same RFX probe's ambient sensor.
    public var pairedAmbient: ChannelKey?
    /// Stable index into the chart palette.
    public var colorIndex: Int

    public init(key: ChannelKey, label: String, role: ProbeRole, target: Temperature? = nil,
                pairedAmbient: ChannelKey? = nil, colorIndex: Int = 0) {
        self.key = key
        self.label = label
        self.role = role
        self.target = target
        self.pairedAmbient = pairedAmbient
        self.colorIndex = colorIndex
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
