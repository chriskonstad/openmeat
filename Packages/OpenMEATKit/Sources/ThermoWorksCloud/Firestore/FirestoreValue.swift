import Foundation

/// A typed Firestore REST value.
/// See https://firebase.google.com/docs/firestore/reference/rest/v1/Value
public indirect enum FirestoreValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case timestamp(Date)
    case reference(String)
    case map([String: FirestoreValue])
    case array([FirestoreValue])
    case null
    /// A value type we don't model (bytes, geoPoint, ...). Kept so decoding never fails on new types.
    case unsupported(String)
}

extension FirestoreValue: Decodable {
    private enum CodingKeys: String, CodingKey {
        case stringValue, integerValue, doubleValue, booleanValue, timestampValue
        case referenceValue, mapValue, arrayValue, nullValue
        case bytesValue, geoPointValue
    }

    private struct MapBody: Decodable { let fields: [String: FirestoreValue]? }
    private struct ArrayBody: Decodable { let values: [FirestoreValue]? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(String.self, forKey: .stringValue) {
            self = .string(s)
        } else if c.contains(.integerValue) {
            // Firestore encodes int64 as a JSON string; tolerate a bare number too.
            if let s = try? c.decode(String.self, forKey: .integerValue), let i = Int64(s) {
                self = .integer(i)
            } else {
                self = .integer(try c.decode(Int64.self, forKey: .integerValue))
            }
        } else if c.contains(.doubleValue) {
            if let d = try? c.decode(Double.self, forKey: .doubleValue) {
                self = .double(d)
            } else {
                // "NaN", "Infinity", "-Infinity" arrive as strings.
                let s = try c.decode(String.self, forKey: .doubleValue)
                self = .double(Double(s) ?? .nan)
            }
        } else if let b = try c.decodeIfPresent(Bool.self, forKey: .booleanValue) {
            self = .bool(b)
        } else if let s = try c.decodeIfPresent(String.self, forKey: .timestampValue) {
            guard let date = FirestoreTimestamp.parse(s) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timestampValue, in: c, debugDescription: "Bad timestamp \(s)")
            }
            self = .timestamp(date)
        } else if let s = try c.decodeIfPresent(String.self, forKey: .referenceValue) {
            self = .reference(s)
        } else if let m = try c.decodeIfPresent(MapBody.self, forKey: .mapValue) {
            self = .map(m.fields ?? [:])
        } else if let a = try c.decodeIfPresent(ArrayBody.self, forKey: .arrayValue) {
            self = .array(a.values ?? [])
        } else if c.contains(.nullValue) {
            self = .null
        } else {
            self = .unsupported(c.allKeys.first?.stringValue ?? "unknown")
        }
    }
}

// MARK: - Lenient accessors

public extension FirestoreValue {
    var stringValue: String? {
        switch self {
        case .string(let s): s
        case .integer(let i): String(i)
        case .reference(let r): r
        default: nil
        }
    }

    /// Doubles, integers, and numeric strings (some fields, e.g. `gatewayRSSI`, flip between types).
    var doubleValue: Double? {
        switch self {
        case .double(let d): d
        case .integer(let i): Double(i)
        case .string(let s): Double(s)
        default: nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let i): Int(exactly: i)
        case .double(let d): d.isFinite ? Int(d) : nil
        case .string(let s): Int(s)
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var dateValue: Date? {
        if case .timestamp(let d) = self { return d }
        return nil
    }

    var mapValue: [String: FirestoreValue]? {
        if case .map(let m) = self { return m }
        return nil
    }

    var arrayValue: [FirestoreValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

/// RFC 3339 timestamps with 0–9 fractional digits, e.g. `2024-05-01T12:34:56.123456Z`.
enum FirestoreTimestamp {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parse(_ raw: String) -> Date? {
        // Normalize the fractional part to exactly 3 digits, which the format style accepts.
        guard let tIndex = raw.firstIndex(of: "T") else { return nil }
        let timePart = raw[tIndex...]
        guard let zoneStart = timePart.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            return nil
        }
        let head = raw[..<zoneStart]
        let zone = raw[zoneStart...]
        var normalized: String
        if let dot = head.firstIndex(of: ".") {
            let fraction = head[head.index(after: dot)...]
            let millis = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            normalized = String(head[..<dot]) + "." + millis
        } else {
            normalized = String(head) + ".000"
        }
        normalized += zone
        return try? Date(normalized, strategy: style)
    }
}
