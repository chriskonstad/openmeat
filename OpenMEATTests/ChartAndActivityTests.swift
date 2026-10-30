import CookCore
import CookSession
import Foundation
import Testing
@testable import OpenMEAT

@Suite("Chart series builder")
struct ChartSeriesBuilderTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let meat = ChannelKey(deviceSerial: "RFX", channel: "1")
    let pit = ChannelKey(deviceSerial: "RFX", channel: "2")

    private func cook(samples: Int = 1_000) -> Cook {
        var cook = Cook(title: "T", startedAt: t0, probes: [
            CookProbe(key: meat, label: "Meat", role: .internal, target: Temperature(fahrenheit: 203)),
            CookProbe(key: pit, label: "Pit", role: .ambient, colorIndex: 1),
        ])
        for i in 0..<samples {
            cook.append(Sample(time: t0.addingTimeInterval(Double(i) * 15), celsius: 20 + Double(i) * 0.05), to: meat)
            cook.append(Sample(time: t0.addingTimeInterval(Double(i) * 15), celsius: 120), to: pit)
        }
        return cook
    }

    @Test func convertsUnitsAndCarriesTargets() throws {
        let series = ChartSeriesBuilder.series(for: cook(samples: 10), unit: .fahrenheit)
        #expect(series.map(\.label) == ["Meat", "Pit"])
        #expect(abs(try #require(series[0].target) - 203) < 0.001)
        #expect(series[1].points.first?.value == 248)
    }

    @Test func hidesSeriesAndDownsamples() {
        let series = ChartSeriesBuilder.series(for: cook(), unit: .celsius, hidden: [pit], maxPointsPerSeries: 100)
        #expect(series.map(\.key) == [meat])
        #expect(series[0].points.count == 100)
    }

    @Test func windowKeepsOnePointOutsideEachEdge() {
        let window = t0.addingTimeInterval(150)...t0.addingTimeInterval(300)
        let points = ChartSeriesBuilder.series(for: cook(), unit: .celsius, window: window)[0].points
        #expect(points.first?.time == t0.addingTimeInterval(135))
        #expect(points.last?.time == t0.addingTimeInterval(315))
    }

    @Test func scrubLookupUsesLatestAtOrBefore() {
        let s = ChartSeriesBuilder.series(for: cook(samples: 10), unit: .celsius)[0]
        #expect(ChartSeriesBuilder.value(at: t0.addingTimeInterval(-1), in: s) == nil)
        #expect(ChartSeriesBuilder.value(at: t0.addingTimeInterval(20), in: s) == s.points[1].value)
        #expect(ChartSeriesBuilder.value(at: t0.addingTimeInterval(10_000), in: s) == s.points.last?.value)
    }

    @Test func yDomainIncludesTargetsAndHasMinimumSpan() {
        let series = ChartSeriesBuilder.series(for: cook(samples: 2), unit: .fahrenheit, hidden: [pit])
        let domain = ChartSeriesBuilder.yDomain(series)
        #expect(domain.contains(203))
        #expect(domain.contains(68))
        #expect(ChartSeriesBuilder.yDomain([]) == 0...100)
    }

    @Test func visibleLengthIsClamped() {
        #expect(ChartSeriesBuilder.clampVisibleLength(60, cookDuration: 3600) == 600)
        #expect(ChartSeriesBuilder.clampVisibleLength(99_999, cookDuration: 3600) == 3600)
        #expect(ChartSeriesBuilder.clampVisibleLength(99_999, cookDuration: 60) == 600)
    }
}

@Suite("Live Activity state mapping")
struct LiveActivityStateTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let meat = ChannelKey(deviceSerial: "RFX", channel: "1")

    private func snapshot(_ estimate: Estimate?, target: Double? = 203) -> SessionSnapshot {
        var cook = Cook(title: "Brisket", startedAt: t0, probes: [
            CookProbe(key: meat, label: "Flat", role: .internal, target: target.map { Temperature(fahrenheit: $0) }),
        ])
        cook.append(Sample(time: t0, celsius: 5), to: meat)
        cook.append(Sample(time: t0.addingTimeInterval(60), celsius: 50), to: meat)
        return SessionSnapshot(cook: cook, estimates: estimate.map { [meat: $0] } ?? [:], staleChannels: [],
                               lastPoll: nil, lastError: nil, now: t0.addingTimeInterval(60))
    }

    @Test func estimatingCarriesETA() {
        let eta = t0.addingTimeInterval(3600)
        let state = CookActivityAttributes.ContentState(snapshot: snapshot(Estimate(state: .estimating, eta: eta)), unit: .fahrenheit)
        #expect(state.probeLabel == "Flat")
        #expect(state.currentCelsius == 50)
        #expect(state.startCelsius == 5)
        #expect(state.eta == eta)
        #expect(state.status == nil)
        #expect(state.unit == "F")
    }

    @Test(arguments: [(EstimateState.stalled, "Stall"), (.warmingUp, "Calculating…"), (.reached, "Done")])
    func statusText(_ estimateState: EstimateState, _ text: String) {
        let state = CookActivityAttributes.ContentState(snapshot: snapshot(Estimate(state: estimateState, eta: t0)), unit: .celsius)
        #expect(state.status == text)
        #expect(state.eta == nil)
    }

    @Test func noTargetHasNoStatus() {
        let state = CookActivityAttributes.ContentState(snapshot: snapshot(nil, target: nil), unit: .celsius)
        #expect(state.status == nil)
        #expect(state.targetCelsius == nil)
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func durations() {
        #expect(Formatting.duration(45) == "45s")
        #expect(Formatting.duration(8 * 60 + 5) == "8m")
        #expect(Formatting.duration(72 * 60) == "1h 12m")
        #expect(Formatting.duration(-5) == "0s")
    }

    @Test func rates() {
        #expect(Formatting.rate(1, unit: .fahrenheit) == "+1.8°/min")
        #expect(Formatting.rate(nil, unit: .celsius) == nil)
    }
}
