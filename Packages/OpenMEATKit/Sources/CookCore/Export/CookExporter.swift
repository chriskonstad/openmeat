import Foundation

public enum CookExporter {
    /// Long-format CSV: `timestamp,elapsed_s,probe,role,temp_<unit>` plus `note` rows.
    public static func csv(_ cook: Cook, unit: TemperatureUnit) -> String {
        let iso = Date.ISO8601FormatStyle()
        var rows = ["timestamp,elapsed_s,probe,role,temp_\(unit.rawValue),note"]
        var events: [(Date, String)] = []
        for probe in cook.probes {
            for sample in cook.series[probe.key] ?? [] {
                let value = sample.temperature.value(in: unit).formatted(.number.precision(.fractionLength(1)).grouping(.never))
                events.append((sample.time, "\(escape(probe.label)),\(probe.role.rawValue),\(value),"))
            }
        }
        for note in cook.notes {
            events.append((note.time, ",,,\(escape(note.text))"))
        }
        for (time, rest) in events.sorted(by: { $0.0 < $1.0 }) {
            let elapsed = Int(time.timeIntervalSince(cook.startedAt))
            rows.append("\(time.formatted(iso)),\(elapsed),\(rest)")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    public static func json(_ cook: Cook) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(cook)
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
