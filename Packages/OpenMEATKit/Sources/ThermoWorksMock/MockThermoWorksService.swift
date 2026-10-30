import CookCore
import Foundation
import Synchronization
import ThermoWorksCloud

/// `ThermoWorksService` backed by `CookSimulator`. Readings are quantized to `transmitInterval`
/// (like real telemetry) and timestamped in the injected `TimeSource`'s timeline.
public final class MockThermoWorksService: ThermoWorksService {
    public let simulator: CookSimulator
    public let startDate: Date
    public let transmitInterval: TimeInterval
    private let time: any TimeSource
    private let failures = Mutex<[ThermoWorksError]>([])

    public init(simulator: CookSimulator, timeSource: any TimeSource, startDate: Date? = nil, transmitInterval: TimeInterval = 15) {
        self.simulator = simulator
        self.time = timeSource
        self.startDate = startDate ?? timeSource.now
        self.transmitInterval = transmitInterval
    }

    public convenience init(scenario: MockScenario, timeSource: any TimeSource, startDate: Date? = nil) {
        self.init(simulator: scenario.simulator, timeSource: timeSource, startDate: startDate)
    }

    /// Makes the next calls throw, in order (error-handling tests).
    public func enqueueFailures(_ errors: [ThermoWorksError]) {
        failures.withLock { $0.append(contentsOf: errors) }
    }

    private func throwIfFailureQueued() throws {
        if let error = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw error }
    }

    public func currentUser() async throws -> TWUser {
        try throwIfFailureQueued()
        return TWUser(uid: "mock-user", accountID: "mock-account", email: "demo@openmeat.app", displayName: "Demo")
    }

    public func devices() async throws -> [TWDevice] {
        try throwIfFailureQueued()
        return simulator.probes.map { probe in
            TWDevice(serial: probe.serial, label: probe.label, type: "rfx", model: "rfx meat",
                     accountID: "mock-account", battery: 87, batteryState: "NORMAL", signalStrength: -58,
                     status: "NORMAL", lastSeen: time.now, transmitInterval: transmitInterval, sessionStart: startDate)
        }
    }

    public func channels(forDevice serial: String) async throws -> [TWChannel] {
        try throwIfFailureQueued()
        guard let probe = simulator.probes.first(where: { $0.serial == serial }) else {
            throw ThermoWorksError.notFound("Device \(serial)")
        }
        return probe.channels.compactMap { channel(serial: serial, $0) }
    }

    public func channels(_ refs: [TWChannelRef]) async throws -> [TWChannel] {
        try throwIfFailureQueued()
        return refs.compactMap { ref in
            simulator.probes.first { $0.serial == ref.deviceSerial }?
                .channels.first { $0.number == ref.number }
                .flatMap { channel(serial: ref.deviceSerial, $0) }
        }
    }

    private func channel(serial: String, _ sim: CookSimulator.Channel) -> TWChannel? {
        let elapsed = time.now.timeIntervalSince(startDate)
        // Last telemetry packet boundary.
        let packetElapsed = max(0, (elapsed / transmitInterval).rounded(.down) * transmitInterval)
        // A dropped-out channel keeps returning its last packet, like a stale Firestore doc.
        let reportedElapsed = sim.dropsOutAfter.map { min($0, packetElapsed) } ?? packetElapsed
        guard let celsius = simulator.celsius(serial: serial, channel: sim.number, at: reportedElapsed) else { return nil }
        let fahrenheit = Temperature(celsius: celsius).fahrenheit
        let saved = startDate.addingTimeInterval(reportedElapsed)
        return TWChannel(
            ref: TWChannelRef(deviceSerial: serial, number: sim.number),
            label: sim.label, type: sim.role == .ambient ? "ambient" : "probe",
            value: (fahrenheit * 10).rounded() / 10, units: "F", status: "NORMAL",
            lastSeen: saved, lastTelemetrySaved: saved)
    }
}
