import Foundation

/// The signed-in ThermoWorks user (`users/{uid}`).
public struct TWUser: Sendable, Equatable {
    public var uid: String
    public var accountID: String?
    public var email: String?
    public var displayName: String?

    public init(uid: String, accountID: String?, email: String? = nil, displayName: String? = nil) {
        self.uid = uid
        self.accountID = accountID
        self.email = email
        self.displayName = displayName
    }

    public init(document: FirestoreDocument) {
        self.init(
            uid: document["uid"]?.stringValue ?? document.documentID,
            accountID: document["accountId"]?.stringValue,
            email: document["email"]?.stringValue,
            displayName: document["displayName"]?.stringValue
        )
    }
}

/// A ThermoWorks device (`devices/{serial}`). For RFX, each meat probe is a device.
public struct TWDevice: Sendable, Equatable, Identifiable {
    public var id: String { serial }
    public var serial: String
    public var label: String?
    /// Device family, e.g. `"rfx"`, `"node"`, `"smoke"`.
    public var type: String?
    /// Model name, e.g. `"rfx meat"`.
    public var model: String?
    public var accountID: String?
    public var battery: Int?
    public var batteryState: String?
    /// Gateway RSSI when present, else Wi-Fi strength (dBm).
    public var signalStrength: Int?
    public var status: String?
    public var lastSeen: Date?
    public var transmitInterval: TimeInterval?
    public var sessionStart: Date?

    public var isRFX: Bool { type?.lowercased() == "rfx" }

    /// The RFX gateway (Wi-Fi bridge for the wireless probes; wired ambient sensors plug into it).
    /// Matched on model/type/label until we confirm the real document shape (docs/SPEC.md §3.3).
    public var isGateway: Bool {
        [model, type, label].compactMap { $0?.lowercased() }.contains { $0.contains("gateway") }
    }

    public init(
        serial: String, label: String? = nil, type: String? = nil, model: String? = nil,
        accountID: String? = nil, battery: Int? = nil, batteryState: String? = nil,
        signalStrength: Int? = nil, status: String? = nil, lastSeen: Date? = nil,
        transmitInterval: TimeInterval? = nil, sessionStart: Date? = nil
    ) {
        self.serial = serial
        self.label = label
        self.type = type
        self.model = model
        self.accountID = accountID
        self.battery = battery
        self.batteryState = batteryState
        self.signalStrength = signalStrength
        self.status = status
        self.lastSeen = lastSeen
        self.transmitInterval = transmitInterval
        self.sessionStart = sessionStart
    }

    public init(document d: FirestoreDocument) {
        self.init(
            serial: d["serial"]?.stringValue ?? d.documentID,
            label: d["label"]?.stringValue,
            type: d["type"]?.stringValue,
            model: d["device"]?.stringValue,
            accountID: d["accountId"]?.stringValue,
            battery: d["battery"]?.intValue,
            batteryState: d["batteryState"]?.stringValue,
            // "wifi_stength" (sic) is the observed field name.
            signalStrength: d["gatewayRSSI"]?.intValue ?? d["wifi_stength"]?.intValue,
            status: d["status"]?.stringValue,
            lastSeen: d["lastSeen"]?.dateValue,
            transmitInterval: d["transmitIntervalInSeconds"]?.doubleValue,
            sessionStart: d["sessionStart"]?.dateValue
        )
    }
}

/// Identifies one channel document.
public struct TWChannelRef: Sendable, Hashable, Codable {
    public var deviceSerial: String
    public var number: String

    public init(deviceSerial: String, number: String) {
        self.deviceSerial = deviceSerial
        self.number = number
    }

    var documentPath: String { "devices/\(deviceSerial)/channels/\(number)" }
}

public struct TWAlarm: Sendable, Equatable {
    public var enabled: Bool?
    public var alarming: Bool?
    public var value: Double?
    public var units: String?

    public init(enabled: Bool? = nil, alarming: Bool? = nil, value: Double? = nil, units: String? = nil) {
        self.enabled = enabled
        self.alarming = alarming
        self.value = value
        self.units = units
    }

    init?(_ value: FirestoreValue?) {
        guard let m = value?.mapValue else { return nil }
        self.init(
            enabled: m["enabled"]?.boolValue,
            alarming: m["alarming"]?.boolValue,
            value: m["value"]?.doubleValue,
            units: m["units"]?.stringValue
        )
    }
}

/// A sensor channel (`devices/{serial}/channels/{n}`).
public struct TWChannel: Sendable, Equatable, Identifiable {
    public var id: TWChannelRef { ref }
    public var ref: TWChannelRef
    public var label: String?
    /// Observed values vary by device; used by role classification.
    public var type: String?
    public var value: Double?
    /// `"F"`, `"C"`, or `"H"` (humidity).
    public var units: String?
    public var status: String?
    public var lastSeen: Date?
    public var lastTelemetrySaved: Date?
    public var alarmHigh: TWAlarm?
    public var alarmLow: TWAlarm?

    public init(
        ref: TWChannelRef, label: String? = nil, type: String? = nil, value: Double? = nil,
        units: String? = nil, status: String? = nil, lastSeen: Date? = nil,
        lastTelemetrySaved: Date? = nil, alarmHigh: TWAlarm? = nil, alarmLow: TWAlarm? = nil
    ) {
        self.ref = ref
        self.label = label
        self.type = type
        self.value = value
        self.units = units
        self.status = status
        self.lastSeen = lastSeen
        self.lastTelemetrySaved = lastTelemetrySaved
        self.alarmHigh = alarmHigh
        self.alarmLow = alarmLow
    }

    /// RFX MEAT's channel 0: ThermoWorks' own core reading (the coldest of the probe's sensors).
    public var isComputed: Bool { type?.lowercased() == "computed" }

    /// One sensor along a multi-sensor probe (RFX MEAT channels 1–4, type "rfx meat sensor").
    public var isProbeSensor: Bool { type?.lowercased().contains("sensor") ?? false }

    public init?(document d: FirestoreDocument) {
        // .../devices/{serial}/channels/{n}
        let path = d.pathSegments
        guard path.count >= 4, path[path.count - 4] == "devices", path[path.count - 2] == "channels" else {
            return nil
        }
        self.init(
            ref: TWChannelRef(deviceSerial: path[path.count - 3], number: d["number"]?.stringValue ?? path[path.count - 1]),
            // Unset labels arrive as "".
            label: d["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            type: d["type"]?.stringValue,
            value: d["value"]?.doubleValue,
            units: d["units"]?.stringValue,
            status: d["status"]?.stringValue,
            lastSeen: d["lastSeen"]?.dateValue,
            lastTelemetrySaved: d["lastTelemetrySaved"]?.dateValue,
            alarmHigh: TWAlarm(d["alarmHigh"]),
            alarmLow: TWAlarm(d["alarmLow"])
        )
    }
}
