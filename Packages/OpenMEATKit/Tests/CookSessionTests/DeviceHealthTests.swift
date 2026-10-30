import CookCore
import Foundation
import Testing
import ThermoWorksCloud
import ThermoWorksMock
@testable import CookSession

@Suite("Device health")
struct DeviceHealthTests {
    private func health(_ percent: Int?, state: String? = nil) -> DeviceHealth.BatteryLevel {
        DeviceHealth(serial: "X", label: "X", isGateway: false, batteryPercent: percent, batteryState: state,
                     signalStrength: nil, lastSeen: nil).battery
    }

    @Test func batteryLevels() {
        #expect(health(80) == .ok(percent: 80))
        #expect(health(50) == .ok(percent: 50))
        #expect(health(49) == .low(percent: 49))       // < 50 → yellow-orange
        #expect(health(20) == .low(percent: 20))
        #expect(health(19) == .critical(percent: 19))  // < 20 → red
        #expect(health(0) == .critical(percent: 0))
        #expect(health(nil) == .none)                              // wired / mains powered
        #expect(health(nil, state: "NORMAL") == .ok(percent: nil))
        #expect(health(nil, state: "LOW") == .low(percent: nil))
        #expect(health(55, state: "LOW") == .low(percent: 55))     // device says low → trust it
        #expect(health(55, state: "CRITICAL") == .critical(percent: 55))
        #expect(health(15).needsAttention)
        #expect(!health(30).needsAttention)          // low is shown, not announced
        #expect(!health(nil).needsAttention)
    }

    @Test func percentIsClampedFromDeviceDocuments() {
        let device = TWDevice(serial: "A", label: "Probe", type: "rfx", model: "rfx meat", battery: 140)
        #expect(DeviceHealth(device: device).batteryPercent == 100)
    }

    @Test func gatewayDetection() {
        #expect(TWDevice(serial: "G", type: "rfx", model: "rfx gateway").isGateway)
        #expect(TWDevice(serial: "G", label: "RFX Gateway").isGateway)
        #expect(!TWDevice(serial: "P", type: "rfx", model: "rfx meat").isGateway)
    }

    @Test func gatewayScenarioHasWiredAmbientAndProbeBatteries() async throws {
        let clock = ManualTimeSource()
        let service = MockThermoWorksService(scenario: .gatewayAmbient, timeSource: clock)
        let devices = try await ProbeDiscovery.discover(using: service)
        let healths = Dictionary(uniqueKeysWithValues: devices.map { ($0.device.serial, $0.health) })
        #expect(healths["RFX-GATEWAY"]?.isGateway == true)
        #expect(healths["RFX-RIBS"]?.battery == .critical(percent: 14))

        let probes = ProbeDiscovery.probes(from: devices)
        let ambient = try #require(probes.first { $0.role == .ambient })
        #expect(ambient.key.deviceSerial == "RFX-GATEWAY")
        #expect(ambient.label == "Ambient")
        // Each RFX MEAT is one meat probe (its computed core) with four hidden sensors.
        let cores = probes.filter { $0.role == .internal }
        #expect(cores.map(\.label) == ["Brisket", "Ribs"])
        #expect(cores.allSatisfy { $0.key.channel == "0" && $0.pairedAmbient == ambient.key })
        #expect(probes.filter { $0.role == .sensor }.count == 8)
    }

    @Test func sessionRefreshesDeviceHealthPeriodically() async throws {
        let clock = ManualTimeSource()
        let service = MockThermoWorksService(scenario: .gatewayAmbient, timeSource: clock)
        let probes = ProbeDiscovery.probes(from: try await ProbeDiscovery.discover(using: service))
            .filter { $0.key.deviceSerial != "RFX-RIBS" }
        var options = LiveCookSession.Options()
        options.deviceRefreshInterval = 600
        let session = LiveCookSession(cook: Cook(title: "T", startedAt: clock.now, probes: probes),
                                      service: service, store: nil, timeSource: clock, options: options)

        let first = await session.pollOnce()
        // Only devices in the cook, plus the gateway.
        #expect(Set(first.devices.keys) == ["RFX-GATEWAY", "RFX-BRISKET"])
        #expect(first.devices["RFX-BRISKET"]?.connection(now: clock.now) == .online)
        #expect(first.devices["RFX-BRISKET"]?.batteryPercent == 92)

        clock.advance(by: 4 * 3600) // brisket drains 1.5 %/h → 86
        #expect(await session.pollOnce().devices["RFX-BRISKET"]?.batteryPercent == 86)
        clock.advance(by: 300)       // inside the refresh interval: unchanged
        #expect(await session.pollOnce().devices["RFX-BRISKET"]?.batteryPercent == 86)
    }

    @Test func deviceFetchFailureKeepsLastKnownValues() async throws {
        let clock = ManualTimeSource()
        let service = MockThermoWorksService(scenario: .gatewayAmbient, timeSource: clock)
        let probes = ProbeDiscovery.probes(from: try await ProbeDiscovery.discover(using: service))
        var options = LiveCookSession.Options()
        options.deviceRefreshInterval = 60
        let session = LiveCookSession(cook: Cook(title: "T", startedAt: clock.now, probes: probes),
                                      service: service, store: nil, timeSource: clock, options: options)
        #expect(await session.pollOnce().devices.count == 3)
        clock.advance(by: 120)
        service.enqueueFailures([.network("down"), .network("down")]) // channels + devices both fail
        let snap = await session.pollOnce()
        #expect(snap.devices.count == 3)
        #expect(snap.lastError != nil)
    }
}

@Suite("Real RFX capture (sanitized)")
struct RealRFXCaptureTests {
    private func discovered() throws -> [DiscoveredDevice] {
        let devices = try JSONDecoder().decode([RunQueryElement].self, from: Fixtures.data("real_rfx_devices_run_query"))
            .compactMap(\.document).map(TWDevice.init(document:))
        func channels(_ name: String) throws -> [TWChannel] {
            try JSONDecoder().decode(ListResponse.self, from: Fixtures.data(name)).documents.compactMap(TWChannel.init(document:))
        }
        let byDevice = ["M100000001": try channels("real_rfx_meat_channels"),
                        "AA:BB:CC:00:00:01": try channels("real_rfx_gateway_channels")]
        return devices.map { DiscoveredDevice(device: $0, channels: byDevice[$0.serial] ?? []) }
    }

    private struct RunQueryElement: Decodable { let document: FirestoreDocument? }
    private struct ListResponse: Decodable { let documents: [FirestoreDocument] }

    @Test func gatewayAndProbeAreRecognized() throws {
        let devices = try discovered()
        let gateway = try #require(devices.first { $0.device.isGateway })
        #expect(gateway.device.model == "rfx gateway")
        #expect(gateway.health.batteryPercent == 60)
        #expect(gateway.health.signalStrength == -65)         // "wifi_stength" (sic)
        let probe = try #require(devices.first { $0.device.model == "rfx meat" })
        #expect(probe.health.batteryPercent == 100)
        #expect(probe.health.signalStrength == -33)           // gatewayRSSI
        #expect(probe.health.transmitInterval == 60)
    }

    @Test func rfxMeatBecomesOneProbeWithFourSensors() throws {
        let probes = ProbeDiscovery.probes(from: try discovered())
        let core = try #require(probes.first { $0.role == .internal })
        #expect(core.key == ChannelKey(deviceSerial: "M100000001", channel: "0"))
        #expect(core.label == "RFX MEAT")
        let sensors = probes.filter { $0.parent == core.key }
        #expect(sensors.map(\.label) == ["Sensor 1", "Sensor 2", "Sensor 3", "Sensor 4"])
        #expect(sensors.allSatisfy { $0.role == .sensor && $0.colorIndex == core.colorIndex })

        // The wired Pro-Series probe on the gateway is the ambient, paired with the core.
        let ambient = try #require(probes.first { $0.role == .ambient })
        #expect(ambient.key == ChannelKey(deviceSerial: "AA:BB:CC:00:00:01", channel: "1"))
        #expect(ambient.label == "Ambient")
        #expect(core.pairedAmbient == ambient.key)
    }

    @Test func coreIsTheColdestSensor() throws {
        let channels = try discovered().flatMap(\.channels).filter { $0.ref.deviceSerial == "M100000001" }
        let core = try #require(channels.first(where: \.isComputed)?.value)
        let sensorValues = channels.filter(\.isProbeSensor).compactMap(\.value)
        let coldest = try #require(sensorValues.min())
        #expect(abs(core - coldest) < 0.01)
        // Unset labels ("") are treated as missing.
        #expect(channels.first(where: \.isComputed)?.label == nil)
    }

    @Test func showSensorsCustomizationAndWiredProbeAsMeat() throws {
        let core = ChannelKey(deviceSerial: "M100000001", channel: "0")
        let wired = ChannelKey(deviceSerial: "AA:BB:CC:00:00:01", channel: "1")
        let probes = ProbeDiscovery.probes(from: try discovered(), customizations: [
            core: ProbeCustomization(showsSensors: true),
            wired: ProbeCustomization(role: .internal),
        ])
        #expect(probes.first { $0.key == core }?.showsSensors == true)
        #expect(probes.first { $0.key == wired }?.role == .internal)
        #expect(probes.first { $0.key == wired }?.label == "Probe 1")
    }
}

@Suite("Cook visibility of sensors")
struct SensorVisibilityTests {
    @Test func sensorsHiddenUntilShown() async throws {
        let clock = ManualTimeSource()
        let service = MockThermoWorksService(scenario: .gatewayAmbient, timeSource: clock)
        let probes = ProbeDiscovery.probes(from: try await ProbeDiscovery.discover(using: service))
        let session = LiveCookSession(cook: Cook(title: "T", startedAt: clock.now, probes: probes),
                                      service: service, store: nil, timeSource: clock)
        let snap = await session.pollOnce()
        let brisket = try #require(snap.cook.probes.first { $0.label == "Brisket" })
        #expect(!snap.cook.visibleProbes.contains { $0.parent == brisket.key })
        // Sensor readings are recorded regardless, so showing them later has history.
        #expect(snap.cook.sensors(of: brisket.key).allSatisfy { snap.cook.series[$0.key]?.isEmpty == false })
        // The core equals the coldest sensor.
        let coreValue = try #require(snap.cook.latestSample(brisket.key)?.celsius)
        let sensorValues = snap.cook.sensors(of: brisket.key).compactMap { snap.cook.latestSample($0.key)?.celsius }
        let coldest = try #require(sensorValues.min())
        #expect(abs(coreValue - coldest) < 0.1)

        await session.setShowsSensors(true, for: brisket.key)
        #expect(await session.cook.visibleProbes.filter { $0.parent == brisket.key }.count == 4)
    }

    @Test func oldCooksWithoutSensorFieldsStillDecode() throws {
        let json = #"{"key":{"deviceSerial":"A","channel":"1"},"label":"X","role":"internal","colorIndex":2}"#
        let probe = try JSONDecoder().decode(CookProbe.self, from: Data(json.utf8))
        #expect(probe.parent == nil)
        #expect(!probe.showsSensors)
    }
}
