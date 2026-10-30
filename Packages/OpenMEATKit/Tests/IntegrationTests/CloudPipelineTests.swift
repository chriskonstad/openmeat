import CookCore
import CookSession
import Foundation
import Synchronization
import Testing
import ThermoWorksCloud
import ThermoWorksMock

/// The real `LiveThermoWorksService` end to end over stubbed HTTP: sign in → discover → poll → record.
@Suite("Integration: cloud client → session")
struct CloudPipelineTests {
    let t0 = Date(timeIntervalSince1970: 1_793_296_800) // 2026-10-29T18:00:00Z, matches fixture telemetry

    @Test func signInDiscoverAndRecord() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        let now = t0
        let (service, project, credentials) = try await LiveThermoWorksService.signIn(
            email: "cook@example.com", password: "pw", http: stub, now: { now })
        #expect(project.projectID == "tw-test")
        #expect(credentials.userID == "test-uid")

        let devices = try await ProbeDiscovery.discover(using: service)
        #expect(devices.map(\.device.serial).sorted() == ["NODE-1", "RFX-TEST-1"])

        let probes = ProbeDiscovery.probes(from: devices)
        #expect(probes.map(\.label) == ["Brisket Probe", "Brisket Probe Ambient"])

        let store = InMemoryCookStore()
        let session = LiveCookSession(cook: Cook(title: "Brisket", startedAt: t0, probes: probes),
                                      service: service, store: store, timeSource: ManualTimeSource(t0))
        let snapshot = await session.pollOnce()
        #expect(snapshot.lastError == nil)
        let tip = try #require(snapshot.cook.series[probes[0].key]?.last)
        #expect(abs(tip.temperature.fahrenheit - 151.3) < 0.001)
        #expect(tip.time == t0)
        #expect(snapshot.cook.series[probes[1].key]?.last?.temperature.fahrenheit == 248)

        _ = try await session.end()
        #expect(try await store.summaries().count == 1)
    }

    @Test func expiredTokenIsRefreshedTransparentlyAndPersisted() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        let clock = ManualTimeSource(t0)
        let persisted = Mutex<[String]>([])
        let (service, _, _) = try await LiveThermoWorksService.signIn(
            email: "cook@example.com", password: "pw", http: stub, now: { clock.now },
            onRefresh: { creds in persisted.withLock { $0.append(creds.idToken) } })

        clock.advance(by: 3600) // token expired
        _ = try await service.channels([TWChannelRef(deviceSerial: "RFX-TEST-1", number: "1")])

        #expect(persisted.withLock { $0 } == ["id-token-2"])
        let batch = try #require(stub.requests(matching: "documents:batchGet").last)
        #expect(batch.value(forHTTPHeaderField: "Authorization") == "Bearer id-token-2")
    }

    @Test func sessionSurvivesTransientCloudErrors() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        stub.on("POST", "documents:batchGet", .json("unavailable", status: 503), .fixture("channels_batch_get"))
        let (service, _, _) = try await LiveThermoWorksService.signIn(email: "a@b.c", password: "pw", http: stub, now: { [t0] in t0 })
        let key = ChannelKey(deviceSerial: "RFX-TEST-1", channel: "1")
        let session = LiveCookSession(
            cook: Cook(title: "T", startedAt: t0, probes: [CookProbe(key: key, label: "Tip", role: .internal)]),
            service: service, store: nil, timeSource: ManualTimeSource(t0))

        #expect(await session.pollOnce().lastError != nil)
        let recovered = await session.pollOnce()
        #expect(recovered.lastError == nil)
        #expect(recovered.cook.series[key]?.count == 1)
    }
}
