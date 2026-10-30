import Foundation
import Testing
import ThermoWorksMock
@testable import ThermoWorksCloud

@Suite("Live ThermoWorks service (stubbed HTTP)")
struct LiveServiceTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(_ stub: StubHTTPClient, idToken: String = "id-token-1") -> LiveThermoWorksService {
        let now = t0
        let auth = ThermoWorksAuthenticator(http: stub, now: { now })
        let creds = AuthCredentials(userID: "test-uid", email: nil, idToken: idToken,
                                    refreshToken: "refresh-token-1", expiresAt: t0.addingTimeInterval(3600))
        return LiveThermoWorksService(project: ThermoWorksProject(projectID: "tw-test", storageBucket: nil),
                                      tokens: TokenManager(credentials: creds, authenticator: auth, now: { now }),
                                      http: stub)
    }

    @Test func devicesQueriesByAccountID() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        let devices = try await service(stub).devices()
        #expect(devices.map(\.serial) == ["RFX-TEST-1", "NODE-1"])

        let query = try #require(stub.requests(matching: "documents:runQuery").first)
        #expect(query.url?.path(percentEncoded: false) == "/v1/projects/tw-test/databases/(default)/documents:runQuery")
        #expect(query.value(forHTTPHeaderField: "Authorization") == "Bearer id-token-1")
        let body = String(decoding: try #require(query.httpBody), as: UTF8.self)
        #expect(body.contains("test-account"))
    }

    @Test func channelsForDeviceAreSortedNaturally() async throws {
        let channels = try await service(.thermoWorksHappyPath()).channels(forDevice: "RFX-TEST-1")
        #expect(channels.map(\.ref.number) == ["1", "2"])
    }

    @Test func batchGetSkipsMissingDocuments() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        let refs = ["1", "2", "9"].map { TWChannelRef(deviceSerial: "RFX-TEST-1", number: $0) }
        let channels = try await service(stub).channels(refs)
        #expect(channels.map(\.ref.number) == ["1", "2"])

        let body = try JSONSerialization.jsonObject(with: try #require(stub.requests(matching: "documents:batchGet").first?.httpBody))
        let names = (body as? [String: [String]])?["documents"]
        #expect(names?.first == "projects/tw-test/databases/(default)/documents/devices/RFX-TEST-1/channels/1")
    }

    @Test func unauthorizedTriggersOneRefreshAndRetry() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        stub.on("GET", "/documents/users/test-uid", .json("{}", status: 401), .fixture("user"))
        let user = try await service(stub).currentUser()
        #expect(user.accountID == "test-account")

        let userRequests = stub.requests(matching: "/documents/users/test-uid")
        #expect(userRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer id-token-1", "Bearer id-token-2"])
    }

    @Test func persistentUnauthorizedSurfacesAsHTTPError() async {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        stub.on("GET", "/documents/users/test-uid", .json("denied", status: 401))
        await #expect(throws: ThermoWorksError.http(status: 401, body: "denied")) {
            try await service(stub).currentUser()
        }
    }

    @Test func notFoundIsTyped() async {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        stub.on("GET", "/documents/devices/NOPE/channels", .json("{}", status: 404))
        await #expect(throws: ThermoWorksError.notFound("Device NOPE")) {
            try await service(stub).channels(forDevice: "NOPE")
        }
    }

    @Test func garbageBodyIsDecodingError() async {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        stub.on("POST", "documents:batchGet", .json("{not json"))
        await #expect {
            try await service(stub).channels([TWChannelRef(deviceSerial: "X", number: "1")])
        } throws: { error in
            if case ThermoWorksError.decoding = error { true } else { false }
        }
    }

    @Test func emptyBatchMakesNoRequest() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        #expect(try await service(stub).channels([]).isEmpty)
        #expect(stub.requests.isEmpty)
    }
}
