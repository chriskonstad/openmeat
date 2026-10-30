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

    @Test func noteNearScrubbedTime() {
        let notes = [CookNote(time: t0.addingTimeInterval(600), text: "Wrapped"),
                     CookNote(time: t0.addingTimeInterval(660), text: "Spritzed")]
        #expect(ChartSeriesBuilder.note(near: t0.addingTimeInterval(645), in: notes, tolerance: 60)?.text == "Spritzed")
        #expect(ChartSeriesBuilder.note(near: t0.addingTimeInterval(590), in: notes, tolerance: 60)?.text == "Wrapped")
        #expect(ChartSeriesBuilder.note(near: t0.addingTimeInterval(3000), in: notes, tolerance: 60) == nil)
        #expect(ChartSeriesBuilder.note(near: t0, in: [], tolerance: 60) == nil)
    }

    @Test func noteFlagsStaggerWhenTheyWouldOverlap() {
        let a = CookNote(time: t0, text: "Wrapped"), b = CookNote(time: t0, text: "Added wood")
        let c = CookNote(time: t0, text: "Flipped")
        let flags = NoteFlagLayout.place([(a, 100), (b, 130), (c, 300)], plotWidth: 350)
        #expect(flags.map(\.row) == [0, 1, 0])
        // Kept inside the plot even when the marker is at the edge.
        let edge = NoteFlagLayout.place([(a, 2), (b, 349)], plotWidth: 350)
        #expect(edge[0].x >= NoteFlagLayout.estimatedWidth("Wrapped") / 2)
        #expect(edge[1].x <= 350 - NoteFlagLayout.estimatedWidth("Added wood") / 2)
        // Off-screen markers get no flag.
        #expect(NoteFlagLayout.place([(a, -10), (b, 400)], plotWidth: 350).isEmpty)
    }

    @Test func tappingNearAMarkerFindsItsNote() {
        let a = CookNote(time: t0, text: "Wrapped"), b = CookNote(time: t0, text: "Spritzed")
        let positions: [(CookNote, CGFloat)] = [(a, 100), (b, 160)]
        #expect(NoteFlagLayout.hit(x: 110, positions: positions, tolerance: 26)?.text == "Wrapped")
        #expect(NoteFlagLayout.hit(x: 140, positions: positions, tolerance: 26)?.text == "Spritzed")
        #expect(NoteFlagLayout.hit(x: 300, positions: positions, tolerance: 26) == nil)
    }

    @Test func fullResolutionSampleLookup() {
        let samples = cook(samples: 10).series[meat]!
        #expect(ChartSeriesBuilder.sample(at: t0.addingTimeInterval(-1), in: samples) == nil)
        #expect(ChartSeriesBuilder.sample(at: t0.addingTimeInterval(29), in: samples) == samples[1])
    }

    static let strideCases: [(visibleMinutes: Int, strideMinutes: Int)] = [(20, 5), (120, 30), (600, 120), (6000, 720)]

    @Test(arguments: strideCases)
    func tickStrideGivesFewLabels(_ testCase: (visibleMinutes: Int, strideMinutes: Int)) {
        let stride = ChartSeriesBuilder.tickStride(visibleLength: TimeInterval(testCase.visibleMinutes * 60))
        #expect(stride == TimeInterval(testCase.strideMinutes * 60))
    }

    @Test func clockTicksAlignToRoundTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_800_000_000 + 7 * 60) // 08:07 UTC
        let ticks = ChartSeriesBuilder.axisTicks(from: start, to: start.addingTimeInterval(3600), visibleLength: 30 * 60,
                                                 alignedToStart: false, calendar: calendar)
        let first = try #require(ticks.first)
        #expect(Int(first.timeIntervalSince1970) % 300 == 0)
        #expect(first >= start && first.timeIntervalSince(start) < 300)
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 300 })
    }

    @Test func elapsedTicksAlignToStart() {
        let ticks = ChartSeriesBuilder.axisTicks(from: t0, to: t0.addingTimeInterval(7200), visibleLength: 7200, alignedToStart: true)
        #expect(ticks.first == t0)
        #expect(ticks.count == 5) // 0, 30, 60, 90, 120 min
        #expect(ChartSeriesBuilder.axisTicks(from: t0, to: t0, visibleLength: 600, alignedToStart: true).isEmpty)
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
        #expect(state.updatedAt == t0.addingTimeInterval(60))
    }

    @Test func freshnessComesFromNewestReadingAcrossChannels() {
        var snap = snapshot(Estimate(state: .estimating, eta: t0.addingTimeInterval(3600)))
        let pit = ChannelKey(deviceSerial: "RFX", channel: "2")
        snap.cook.probes.append(CookProbe(key: pit, label: "Pit", role: .ambient))
        snap.cook.append(Sample(time: t0.addingTimeInterval(90), celsius: 120), to: pit)
        let state = CookActivityAttributes.ContentState(snapshot: snap, unit: .fahrenheit)
        #expect(state.updatedAt == t0.addingTimeInterval(90))
        #expect(!state.isDataStale)

        snap.staleChannels = Set(snap.cook.probes.map(\.key))
        #expect(CookActivityAttributes.ContentState(snapshot: snap, unit: .fahrenheit).isDataStale)
    }

    @Test func wallClockMappingAppliesToTimes() {
        let eta = t0.addingTimeInterval(3600)
        let state = CookActivityAttributes.ContentState(
            snapshot: snapshot(Estimate(state: .estimating, eta: eta)), unit: .fahrenheit,
            wallClock: { $0.addingTimeInterval(-1000) })
        #expect(state.eta == eta.addingTimeInterval(-1000))
        #expect(state.updatedAt == t0.addingTimeInterval(-940))
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

    @Test func elapsedAxisLabels() {
        #expect(Formatting.elapsedAxis(0) == "0m")
        #expect(Formatting.elapsedAxis(45 * 60) == "45m")
        #expect(Formatting.elapsedAxis(2 * 3600) == "2h")
        #expect(Formatting.elapsedAxis(2 * 3600 + 30 * 60) == "2h30")
    }

    @Test func rates() {
        #expect(Formatting.rate(1, unit: .fahrenheit) == "+1.8°/min")
        #expect(Formatting.rate(nil, unit: .celsius) == nil)
    }
}
