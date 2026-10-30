import Foundation
import Testing
@testable import CookCore

@Suite("Temperature")
struct TemperatureTests {
    @Test func conversions() {
        #expect(Temperature(fahrenheit: 212).celsius == 100)
        #expect(abs(Temperature(celsius: 93.888_888).fahrenheit - 201) < 0.001)
        #expect(Temperature(203, .fahrenheit) == Temperature(fahrenheit: 203))
        #expect(Temperature.deltaCelsius(10, in: .fahrenheit) == 18)
    }

    @Test func unitCodes() {
        #expect(TemperatureUnit(code: "f") == .fahrenheit)
        #expect(TemperatureUnit(code: "C") == .celsius)
        #expect(TemperatureUnit(code: "H") == nil)
        #expect(TemperatureUnit(code: nil) == nil)
    }

    @Test func formatting() {
        #expect(Temperature(fahrenheit: 203).formatted(.fahrenheit) == "203°F")
        #expect(Temperature(celsius: 52.25).formatted(.celsius, fractionDigits: 1, symbol: false) == "52.2"
            || Temperature(celsius: 52.25).formatted(.celsius, fractionDigits: 1, symbol: false) == "52.3")
    }
}

@Suite("Cook model")
struct CookModelTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let key = ChannelKey(deviceSerial: "RFX-1", channel: "1")

    @Test func appendKeepsSeriesStrictlyIncreasing() {
        var cook = Cook(title: "T", startedAt: t0)
        let accepted = [
            cook.append(Sample(time: t0, celsius: 1), to: key),
            cook.append(Sample(time: t0, celsius: 2), to: key),
            cook.append(Sample(time: t0.addingTimeInterval(-1), celsius: 3), to: key),
            cook.append(Sample(time: t0.addingTimeInterval(1), celsius: 4), to: key),
        ]
        #expect(accepted == [true, false, false, true])
        #expect(cook.series[key]?.map(\.celsius) == [1, 4])
    }

    @Test func seriesEncodesAsObjectKeyedByChannel() throws {
        var cook = Cook(title: "T", startedAt: t0)
        cook.append(Sample(time: t0, celsius: 1), to: key)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cook)) as? [String: Any]
        let series = json?["series"] as? [String: Any]
        #expect(series?.keys.first == "RFX-1#1")

        let decoded = try JSONDecoder().decode(Cook.self, from: JSONEncoder().encode(cook))
        #expect(decoded == cook)
    }

    @Test func durationUsesEndWhenFinished() {
        var cook = Cook(title: "T", startedAt: t0)
        #expect(cook.duration(asOf: t0.addingTimeInterval(60)) == 60)
        cook.endedAt = t0.addingTimeInterval(30)
        #expect(cook.duration(asOf: t0.addingTimeInterval(60)) == 30)
        #expect(!cook.isActive)
    }

    @Test func summaryPeakUsesInternalProbesOnly() {
        let ambient = ChannelKey(deviceSerial: "RFX-1", channel: "2")
        var cook = Cook(title: "T", startedAt: t0, probes: [
            CookProbe(key: key, label: "Brisket", role: .internal),
            CookProbe(key: ambient, label: "Pit", role: .ambient),
        ])
        cook.append(Sample(time: t0, celsius: 90), to: key)
        cook.append(Sample(time: t0, celsius: 120), to: ambient)
        let summary = CookSummary(cook)
        #expect(summary.peakCelsius == 90)
        #expect(summary.probeLabels == ["Brisket"])
    }
}

@Suite("Time sources")
struct TimeSourceTests {
    @Test func manualAdvances() {
        let clock = ManualTimeSource(Date(timeIntervalSince1970: 0))
        clock.advance(by: 90)
        #expect(clock.now == Date(timeIntervalSince1970: 90))
    }

    @Test func scaledRunsFaster() {
        let base = ManualTimeSource(Date(timeIntervalSince1970: 0))
        let scaled = ScaledTimeSource(anchor: base.now, scale: 600, base: base)
        base.advance(by: 6)
        #expect(scaled.now == Date(timeIntervalSince1970: 3600))
        #expect(scaled.wallClock(for: Date(timeIntervalSince1970: 7200)) == Date(timeIntervalSince1970: 12))
    }
}
