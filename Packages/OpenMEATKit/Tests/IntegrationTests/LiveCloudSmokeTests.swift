import CookSession
import Foundation
import Testing
import ThermoWorksCloud

/// Hits the real ThermoWorks Cloud. Skipped unless credentials are in the environment:
///
///     THERMOWORKS_EMAIL=… THERMOWORKS_PASSWORD=… swift test --filter LiveCloudSmokeTests
///
/// Read-only. Never runs in CI by default.
enum LiveCredentials {
    static var value: (email: String, password: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["THERMOWORKS_EMAIL"], let password = env["THERMOWORKS_PASSWORD"] else { return nil }
        return (email, password)
    }
}

@Suite("Live cloud smoke test", .enabled(if: LiveCredentials.value != nil, "set THERMOWORKS_EMAIL / THERMOWORKS_PASSWORD"))
struct LiveCloudSmokeTests {

    @Test func signInAndReadChannels() async throws {
        let creds = try #require(LiveCredentials.value)
        let (service, _, _) = try await LiveThermoWorksService.signIn(email: creds.email, password: creds.password)
        let user = try await service.currentUser()
        #expect(user.accountID != nil)

        let devices = try await ProbeDiscovery.discover(using: service)
        for device in devices {
            print("[smoke] \(device.device.type ?? "?") \(device.device.serial) \(device.device.label ?? ""): "
                + device.channels.map { "#\($0.ref.number) \($0.type ?? "?")/\($0.label ?? "?")=\($0.value ?? .nan)\($0.units ?? "")" }
                .joined(separator: ", "))
        }
        if let first = devices.first(where: { !$0.channels.isEmpty }) {
            let polled = try await service.channels(first.channels.map(\.ref))
            #expect(polled.count == first.channels.count)
        }
    }
}
