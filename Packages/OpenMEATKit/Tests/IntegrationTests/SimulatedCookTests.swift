import CookCore
import CookSession
import Foundation
import Testing
import ThermoWorksMock

/// Full simulated cooks through the session: estimator replay accuracy, alerts, persistence, export.
@Suite("Integration: simulated cooks")
struct SimulatedCookTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    struct Trace {
        var cook: Cook
        /// (time, estimate) for the first internal probe at every poll.
        var estimates: [(Date, Estimate)]
        var reachedAt: Date?
    }

    /// Runs a scenario at 15 s polls until the first internal probe reaches `targetF` (or `maxHours`).
    private func run(_ scenario: MockScenario, targetF: Double, maxHours: Double, store: (any CookStore)? = nil) async throws -> Trace {
        let clock = ManualTimeSource(t0)
        let service = MockThermoWorksService(scenario: scenario, timeSource: clock)
        var probes = ProbeDiscovery.probes(from: try await ProbeDiscovery.discover(using: service))
        let index = try #require(probes.firstIndex { $0.role == .internal })
        probes[index].target = Temperature(fahrenheit: targetF)
        let key = probes[index].key
        let session = LiveCookSession(cook: Cook(title: scenario.rawValue, startedAt: t0, probes: probes),
                                      service: service, store: store, timeSource: clock)
        var trace = Trace(cook: await session.cook, estimates: [])
        while clock.now.timeIntervalSince(t0) < maxHours * 3600 {
            let snap = await session.pollOnce()
            if let e = snap.estimates[key] {
                trace.estimates.append((clock.now, e))
                if e.state == .reached { trace.reachedAt = clock.now; break }
            }
            clock.advance(by: 15)
        }
        trace.cook = try await session.end()
        return trace
    }

    /// Mean absolute percentage error of remaining-time predictions over a fraction of the cook.
    private func remainingTimeError(_ trace: Trace, from startFraction: Double, to endFraction: Double = 0.95) throws -> Double {
        let done = try #require(trace.reachedAt)
        let total = done.timeIntervalSince(t0)
        let window = trace.estimates.filter {
            let f = $0.0.timeIntervalSince(t0) / total
            return f >= startFraction && f <= endFraction && $0.1.state == .estimating
        }
        try #require(!window.isEmpty)
        let errors = window.compactMap { time, estimate -> Double? in
            guard let eta = estimate.eta else { return nil }
            let truth = done.timeIntervalSince(time)
            return abs(eta.timeIntervalSince(time) - truth) / truth
        }
        return errors.reduce(0, +) / Double(errors.count)
    }

    @Test func chickenReachesTargetWithAccurateETA() async throws {
        let trace = try await run(.chickenFast, targetF: 165, maxHours: 4)
        #expect(trace.reachedAt != nil)
        let mape = try remainingTimeError(trace, from: 0.4)
        #expect(mape < 0.15, "remaining-time error \(mape)")
    }

    @Test func brisketStallIsDetectedAndETARecoversAfterwards() async throws {
        let trace = try await run(.brisketStall, targetF: 203, maxHours: 24)
        #expect(trace.reachedAt != nil)
        #expect(trace.estimates.contains { $0.1.state == .stalled })
        // Pure Newton can't foresee a stall (pre-stall ETAs run hours early — see SPEC §6).
        // Once the stall clears and the EWMA has had two half-lives to recover, it should be accurate.
        let done = try #require(trace.reachedAt)
        let stallEnd = try #require(trace.estimates.last { $0.1.state == .stalled }?.0)
        let recovered = stallEnd.addingTimeInterval(2 * EstimatorConfiguration().halfLife)
        let mape = try remainingTimeError(trace, from: recovered.timeIntervalSince(t0) / done.timeIntervalSince(t0))
        #expect(mape < 0.15, "post-stall remaining-time error \(mape)")
    }

    @Test func noAmbientUsesLinearEstimates() async throws {
        let trace = try await run(.noAmbient, targetF: 140, maxHours: 6)
        #expect(trace.estimates.contains { $0.1.method == .linear })
        #expect(!trace.estimates.contains { $0.1.method == .newton })
    }

    @Test func alertsArePlannedFromLiveEstimates() async throws {
        let trace = try await run(.chickenFast, targetF: 165, maxHours: 4)
        let (time, estimate) = try #require(trace.estimates.last { $0.1.state == .estimating })
        var cook = trace.cook
        cook.endedAt = nil
        let key = try #require(cook.probes.first { $0.role == .internal }?.key)
        let alerts = AlertPlanner(unit: .fahrenheit).plan(cook: cook, estimates: [key: estimate], leadTime: 300, now: time)
        #expect(alerts.contains { $0.kind == .almostDone })
    }

    @Test func finishedCookPersistsAndExports() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "openmeat-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileCookStore(directory: dir)
        let trace = try await run(.twoProbesSteak, targetF: 125, maxHours: 3, store: store)

        let loaded = try await store.load(id: trace.cook.id)
        #expect(loaded == trace.cook)
        #expect(loaded.series.count == 4)
        let csv = CookExporter.csv(loaded, unit: .fahrenheit)
        let rows = csv.split(separator: "\n").count - 1
        #expect(rows == loaded.series.values.map(\.count).reduce(0, +))
    }
}
