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
        let fresh = await session.pollOnce()
        #expect(fresh.staleChannels.isEmpty)
        #expect(!fresh.isStale)
        clock.advance(by: 600)
        let stale = await session.pollOnce()
        #expect(stale.staleChannels.count == 2)
        #expect(stale.isStale)
        // The last packet was at the 2 h dropout, not "now".
        #expect(stale.latestReadingTime == t0.addingTimeInterval(2 * 3600))
    }

    @Test func latestReadingTimeBeforeAnyData() async throws {
        let (session, _, _) = try await makeSession()
        let snap = await session.snapshot()
        #expect(snap.latestReadingTime == nil)
        #expect(!snap.isStale)
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

@Suite("Probe customization and pairing")
struct ProbeCustomizationTests {
    private func device(_ serial: String, label: String, channels: [(String, String)]) -> DiscoveredDevice {
        DiscoveredDevice(
            device: TWDevice(serial: serial, label: label, type: "rfx"),
            channels: channels.map { TWChannel(ref: TWChannelRef(deviceSerial: serial, number: $0.0), label: $0.1, value: 100, units: "F") })
    }

    private var twoProbes: [DiscoveredDevice] {
        [device("A", label: "Brisket", channels: [("1", "Tip"), ("2", "Ambient")]),
         device("B", label: "Ribs", channels: [("1", "Tip")])]
    }

    @Test func automaticRolesPairingAndColors() {
        let probes = ProbeDiscovery.probes(from: twoProbes)
        let a1 = ChannelKey(deviceSerial: "A", channel: "1"), a2 = ChannelKey(deviceSerial: "A", channel: "2")
        let b1 = ChannelKey(deviceSerial: "B", channel: "1")
        #expect(probes.map(\.role) == [.internal, .ambient, .internal])
        // Ribs has no ambient of its own → shares the cook's pit sensor.
        #expect(probes.map(\.pairedAmbient) == [a2, nil, a2])
        // One color per meat probe; an ambient shared by both probes is neutral.
        #expect(probes.first { $0.key == a1 }?.colorIndex == 0)
        #expect(probes.first { $0.key == b1 }?.colorIndex == 1)
        #expect(probes.first { $0.key == a2 }?.colorIndex == CookProbe.neutralColor)
    }

    @Test func customizationsOverrideRoleAndLabel() {
        let a1 = ChannelKey(deviceSerial: "A", channel: "1"), a2 = ChannelKey(deviceSerial: "A", channel: "2")
        let probes = ProbeDiscovery.probes(from: twoProbes, customizations: [
            a1: ProbeCustomization(role: .ambient, label: "Pit (left)"),
            a2: ProbeCustomization(role: .internal, label: "  "),
        ])
        #expect(probes.first { $0.key == a1 }?.role == .ambient)
        #expect(probes.first { $0.key == a1 }?.label == "Pit (left)")
        #expect(probes.first { $0.key == a2 }?.role == .internal)
        #expect(probes.first { $0.key == a2 }?.label == "Brisket") // blank custom label falls back
        #expect(probes.first { $0.key == a2 }?.pairedAmbient == a1)
    }

    @Test func customizationCodableRoundTrip() throws {
        let original = [ChannelKey(deviceSerial: "A", channel: "1"): ProbeCustomization(role: .ambient, label: "Pit", isIncluded: false)]
        let decoded = try JSONDecoder().decode([ChannelKey: ProbeCustomization].self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func midCookRoleChangeRepairsWithoutRepainting() async throws {
        let clock = ManualTimeSource()
        let service = MockThermoWorksService(scenario: .twoProbesSteak, timeSource: clock)
        var probes = ProbeDiscovery.probes(from: try await ProbeDiscovery.discover(using: service))
        let ribeyeTip = try #require(probes.first { $0.key.deviceSerial == "RFX-RIBEYE" && $0.role == .internal })
        let stripTip = try #require(probes.first { $0.key.deviceSerial == "RFX-STRIP" && $0.role == .internal })
        probes = probes.map { var p = $0; if p.role == .internal { p.target = Temperature(fahrenheit: 130) }; return p }
        let session = LiveCookSession(cook: Cook(title: "T", startedAt: clock.now, probes: probes), service: service,
                                      store: nil, timeSource: clock)

        await session.setRole(.ambient, for: ribeyeTip.key)
        let after = await session.cook.probes
        let changed = try #require(after.first { $0.key == ribeyeTip.key })
        #expect(changed.role == .ambient)
        #expect(changed.target == nil)
        #expect(after.first { $0.key == stripTip.key }?.colorIndex == stripTip.colorIndex)
        #expect(await session.snapshot().estimates[ribeyeTip.key] == nil)

        await session.setLabel("Pit", for: ribeyeTip.key)
        #expect(await session.cook.probe(ribeyeTip.key)?.label == "Pit")
    }
}
