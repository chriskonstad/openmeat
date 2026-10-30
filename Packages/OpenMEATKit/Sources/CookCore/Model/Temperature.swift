import Foundation

public enum TemperatureUnit: String, Codable, Sendable, CaseIterable {
    case fahrenheit = "F"
    case celsius = "C"

    /// Parses ThermoWorks unit codes (`"F"`, `"C"`). Returns nil for non-temperature units such as `"H"`.
    public init?(code: String?) {
        guard let code else { return nil }
        self.init(rawValue: code.uppercased())
    }

    public var symbol: String { self == .fahrenheit ? "°F" : "°C" }
}

/// A temperature, stored canonically in Celsius.
public struct Temperature: Codable, Hashable, Comparable, Sendable {
    public var celsius: Double

    public init(celsius: Double) { self.celsius = celsius }
    public init(fahrenheit: Double) { self.celsius = (fahrenheit - 32) * 5 / 9 }
    public init(_ value: Double, _ unit: TemperatureUnit) {
        self = unit == .celsius ? Temperature(celsius: value) : Temperature(fahrenheit: value)
    }

    public var fahrenheit: Double { celsius * 9 / 5 + 32 }

    public func value(in unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : fahrenheit
    }

    public func formatted(_ unit: TemperatureUnit, fractionDigits: Int = 0, symbol: Bool = true) -> String {
        let number = value(in: unit).formatted(.number.precision(.fractionLength(fractionDigits)))
        return symbol ? number + unit.symbol : number
    }

    public static func < (lhs: Temperature, rhs: Temperature) -> Bool { lhs.celsius < rhs.celsius }

    /// Converts a temperature *difference* (not an absolute temperature).
    public static func deltaCelsius(_ delta: Double, in unit: TemperatureUnit) -> Double {
        unit == .celsius ? delta : delta * 9 / 5
    }
}
