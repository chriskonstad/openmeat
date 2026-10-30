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
        #expect(health(21) == .ok(percent: 21))
        #expect(health(20) == .low(percent: 20))
        #expect(health(10) == .critical(percent: 10))
        #expect(health(0) == .critical(percent: 0))
        #expect(health(nil) == .none)                              // wired / mains powered
        #expect(health(nil, state: "NORMAL") == .ok(percent: nil))
        #expect(health(nil, state: "LOW") == .low(percent: nil))
        #expect(health(55, state: "LOW") == .low(percent: 55))     // device says low → trust it
        #expect(health(55, state: "CRITICAL") == .critical(percent: 55))
        #expect(health(15).needsAttention)
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
        #expect(healths["RFX-RIBS"]?.battery == .critical(percent: 14) || healths["RFX-RIBS"]?.battery == .low(percent: 14))

        let probes = ProbeDiscovery.probes(from: devices)
        let ambient = try #require(probes.first { $0.role == .ambient })
        #expect(ambient.key.deviceSerial == "RFX-GATEWAY")
        #expect(ambient.label == "Ambient")
        // Every meat probe pairs with the gateway's wired ambient sensor.
        #expect(probes.filter { $0.role == .internal }.allSatisfy { $0.pairedAmbient == ambient.key })
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
