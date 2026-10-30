import Foundation
import Testing
import ThermoWorksMock
@testable import ThermoWorksCloud

@Suite("ThermoWorks models")
struct ModelTests {
    private func runQueryDocuments() throws -> [FirestoreDocument] {
        try JSONDecoder().decode([FirestoreRunQueryElement].self, from: Fixtures.data("devices_run_query"))
            .compactMap(\.document)
    }

    @Test func rfxDeviceFromFixture() throws {
        let device = TWDevice(document: try #require(runQueryDocuments().first))
        #expect(device.serial == "RFX-TEST-1")
        #expect(device.isRFX)
        #expect(device.model == "rfx meat")
        #expect(device.battery == 92)
        #expect(device.signalStrength == -55) // gatewayRSSI delivered as a string
        #expect(device.transmitInterval == 15)
    }

    @Test func signalStrengthFallsBackToWifi() throws {
        let node = TWDevice(document: try runQueryDocuments()[1])
        #expect(!node.isRFX)
        #expect(node.signalStrength == -61)
    }

    @Test func channelFromDocument() throws {
        let page = try JSONDecoder().decode(FirestoreListResponse.self, from: Fixtures.data("channels_list"))
        let channels = try #require(page.documents).compactMap(TWChannel.init(document:))
        #expect(channels.count == 2)
        #expect(channels[0].ref == TWChannelRef(deviceSerial: "RFX-TEST-1", number: "1"))
        #expect(channels[0].value == 151.3)
        #expect(channels[1].value == 248) // integerValue accepted for value
        #expect(channels[0].alarmHigh?.value == 203)
        #expect(channels[0].lastTelemetrySaved != nil)
    }

    @Test func channelRejectsNonChannelPaths() {
        let doc = FirestoreDocument(name: "projects/p/databases/(default)/documents/devices/X", fields: [:])
        #expect(TWChannel(document: doc) == nil)
    }

    @Test func documentPathSegments() {
        let doc = FirestoreDocument(name: "projects/p/databases/(default)/documents/users/u1", fields: [:])
        #expect(doc.pathSegments == ["users", "u1"])
        #expect(doc.documentID == "u1")
    }

    @Test(arguments: [
        ("INVALID_PASSWORD", AuthFailureReason.invalidPassword),
        ("EMAIL_NOT_FOUND", .emailNotFound),
        ("INVALID_LOGIN_CREDENTIALS", .invalidLoginCredentials),
        ("TOO_MANY_ATTEMPTS_TRY_LATER : Access disabled", .tooManyAttempts),
        ("SOMETHING_NEW", .other("SOMETHING_NEW")),
    ])
    func authFailureMapping(_ message: String, _ expected: AuthFailureReason) {
        #expect(AuthFailureReason(firebaseMessage: message) == expected)
    }
}
