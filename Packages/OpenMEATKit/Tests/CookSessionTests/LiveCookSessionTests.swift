import CookCore
import Foundation
import Testing
import ThermoWorksCloud
import ThermoWorksMock
@testable import CookSession

@Suite("Live cook session")
struct LiveCookSessionTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(
        _ scenario: MockScenario = .chickenFast, store: (any CookStore)? = nil, target: Double? = 165
    ) async throws -> (LiveCookSession, ManualTimeSource, MockThermoWorksService) {
        let clock = ManualTimeSource(t0)
        let service = MockThermoWorksService(scenario: scenario, timeSource: clock)
        var probes = ProbeDiscovery.probes(from: try await ProbeDiscovery.discover(using: service))
        for i in probes.indices where probes[i].role == .internal {
            probes[i].target = target.map { Temperature(fahrenheit: $0) }
        }
        let cook = Cook(title: "Test", startedAt: t0, probes: probes)
        let session = LiveCookSession(cook: cook, service: service, store: store, timeSource: clock)
        return (session, clock, service)
    }

    @Test func discoveryPairsInternalWithAmbient() async throws {
        let (session, _, _) = try await makeSession()
        let probes = await session.cook.probes
        #expect(probes.map(\.role) == [.internal, .ambient])
        #expect(probes[0].pairedAmbient == probes[1].key)
        #expect(probes[0].label == "Chicken")
        #expect(probes[1].label == "Chicken Ambient")
    }

    @Test func pollRecordsSamplesInCelsiusAndDedupes() async throws {
        let (session, clock, _) = try await makeSession()
        await session.pollOnce()
        clock.advance(by: 5) // same telemetry packet (15 s transmit interval)
        let snap = await session.pollOnce()
        let tip = try #require(snap.cook.probes.first)
        let samples = try #require(snap.cook.series[tip.key])
        #expect(samples.count == 1)
        #expect(abs(samples[0].celsius - Temperature(fahrenheit: 40).celsius) < 0.5)

        clock.advance(by: 15)
        #expect(await session.pollOnce().cook.series[tip.key]?.count == 2)
    }

    @Test func estimateProgressesFromWarmupToEstimating() async throws {
        let (session, clock, _) = try await makeSession()
        let key = try #require(await session.cook.probes.first?.key)
        #expect(await session.pollOnce().estimates[key]?.state == .warmingUp)
        for _ in 0..<(20 * 4) { // 20 minutes at 15 s
            clock.advance(by: 15)
            await session.pollOnce()
        }
        let estimate = try #require(await session.snapshot().estimates[key])
        #expect(estimate.state == .estimating)
        #expect(estimate.method == .newton)
        #expect(estimate.eta.map { $0 > clock.now } == true)
    }

    @Test func probesWithoutTargetHaveNoEstimate() async throws {
        let (session, _, _) = try await makeSession(target: nil)
        #expect(await session.pollOnce().estimates.isEmpty)
    }

    @Test func serviceErrorsAreSurfacedThenCleared() async throws {
        let (session, clock, service) = try await makeSession()
        service.enqueueFailures([.network("offline")])
        #expect(await session.pollOnce().lastError == ThermoWorksError.network("offline").localizedDescription)
        clock.advance(by: 15)
        #expect(await session.pollOnce().lastError == nil)
    }

    @Test func droppedOutProbeBecomesStale() async throws {
        let (session, clock, _) = try await makeSession(.probeDisconnects)
        clock.advance(by: 2 * 3600 - 60)
        #expect(await session.pollOnce().staleChannels.isEmpty)
        clock.advance(by: 600)
        #expect(await session.pollOnce().staleChannels.count == 2)
    }

    @Test func notesAndTargetsUpdateSnapshot() async throws {
        let (session, clock, _) = try await makeSession()
        clock.advance(by: 30)
        let note = await session.addNote("Wrapped", isQuickNote: true)
        #expect(note.time == clock.now)
        let earlier = await session.addNote("Lit fire", at: t0)
        #expect(await session.cook.notes.map(\.id) == [earlier.id, note.id])
        await session.deleteNote(id: earlier.id)
        #expect(await session.cook.notes.map(\.text) == ["Wrapped"])

        let key = try #require(await session.cook.probes.first?.key)
        await session.setTarget(Temperature(fahrenheit: 180), for: key)
        #expect(await session.cook.probe(key)?.target == Temperature(fahrenheit: 180))
    }

    @Test func snapshotStreamEmitsCurrentThenUpdates() async throws {
        let (session, _, _) = try await makeSession()
        let stream = await session.snapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.cook.notes.isEmpty == true)
        await session.addNote("Hi")
        #expect(await iterator.next()?.cook.notes.count == 1)
    }

    @Test func endPersistsAndFinishesStreams() async throws {
        let store = InMemoryCookStore()
        let (session, clock, _) = try await makeSession(store: store)
        let stream = await session.snapshots()
        await session.pollOnce()
        clock.advance(by: 600)
        let ended = try await session.end()
        #expect(ended.endedAt == clock.now)
        #expect(try await store.load(id: ended.id).endedAt == ended.endedAt)
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count >= 1) // stream terminated
    }

    @Test func resumingRebuildsEstimatorState() async throws {
        let (session, clock, service) = try await makeSession()
        for _ in 0..<(30 * 4) {
            clock.advance(by: 15)
            await session.pollOnce()
        }
        let cook = await session.cook
        let key = try #require(cook.probes.first?.key)
        let original = try #require(await session.snapshot().estimates[key])

        let resumed = LiveCookSession(cook: cook, service: service, store: nil, timeSource: clock)
        let rebuilt = try #require(await resumed.snapshot().estimates[key])
        #expect(rebuilt.state == original.state)
        #expect(rebuilt.eta == original.eta)
    }

    @Test func primaryProbeIsSoonestETA() async throws {
        let (session, clock, _) = try await makeSession(.twoProbesSteak, target: 130)
        for _ in 0..<(20 * 4) {
            clock.advance(by: 15)
            await session.pollOnce()
        }
        let snap = await session.snapshot()
        let soonest = snap.estimates.min { ($0.value.eta ?? .distantFuture) < ($1.value.eta ?? .distantFuture) }
        #expect(snap.primaryProbe?.key == soonest?.key)
    }
}

@Suite("Channel role classifier")
struct ChannelRoleClassifierTests {
    private func channel(label: String?, type: String?, units: String? = "F") -> TWChannel {
        TWChannel(ref: TWChannelRef(deviceSerial: "X", number: "1"), label: label, type: type, value: 100, units: units)
    }

    @Test func classifies() {
        #expect(ChannelRoleClassifier.role(of: channel(label: "Ambient", type: nil)) == .ambient)
        #expect(ChannelRoleClassifier.role(of: channel(label: nil, type: "AMB")) == .ambient)
        #expect(ChannelRoleClassifier.role(of: channel(label: "Pit", type: nil)) == .ambient)
        #expect(ChannelRoleClassifier.role(of: channel(label: "Tip", type: "probe")) == .internal)
        #expect(ChannelRoleClassifier.role(of: channel(label: "Humidity", type: nil, units: "H")) == .unknown)
    }
}
