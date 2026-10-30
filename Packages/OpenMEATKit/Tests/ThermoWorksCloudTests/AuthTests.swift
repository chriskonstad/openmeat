import Foundation
import Synchronization
import Testing
import ThermoWorksMock
@testable import ThermoWorksCloud

@Suite("Authentication")
struct AuthTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func authenticator(_ stub: StubHTTPClient, now: Date? = nil) -> ThermoWorksAuthenticator {
        let fixed = now ?? t0
        return ThermoWorksAuthenticator(http: stub, now: { fixed })
    }

    @Test func signInSendsPasswordGrantAndComputesExpiry() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        let creds = try await authenticator(stub).signIn(email: "cook@example.com", password: "pw")

        #expect(creds.userID == "test-uid")
        #expect(creds.idToken == "id-token-1")
        #expect(creds.expiresAt == t0.addingTimeInterval(3600))

        let request = try #require(stub.requests(matching: "accounts:signInWithPassword").first)
        #expect(request.url?.query()?.contains("key=") == true)
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.thermoworks.com/")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["email"] as? String == "cook@example.com")
        #expect(body?["returnSecureToken"] as? Bool == true)
    }

    @Test func badPasswordMapsToTypedError() async {
        let stub = StubHTTPClient()
        stub.on("POST", "accounts:signInWithPassword", .fixture("auth_error_invalid_password", status: 400))
        await #expect(throws: ThermoWorksError.authenticationFailed(.invalidPassword)) {
            try await authenticator(stub).signIn(email: "a@b.c", password: "nope")
        }
    }

    @Test func serverErrorIsHTTPError() async {
        let stub = StubHTTPClient()
        stub.on("POST", "accounts:signInWithPassword", .json("oops", status: 503))
        await #expect(throws: ThermoWorksError.http(status: 503, body: "oops")) {
            try await authenticator(stub).signIn(email: "a@b.c", password: "pw")
        }
    }

    @Test func fetchProject() async throws {
        let project = try await authenticator(.thermoWorksHappyPath()).fetchProject()
        #expect(project == ThermoWorksProject(projectID: "tw-test", storageBucket: "tw-test.appspot.com"))
    }

    @Test func refreshKeepsEmail() async throws {
        let creds = AuthCredentials(userID: "test-uid", email: "cook@example.com", idToken: "old",
                                    refreshToken: "refresh-token-1", expiresAt: t0)
        let refreshed = try await authenticator(.thermoWorksHappyPath()).refresh(creds)
        #expect(refreshed.idToken == "id-token-2")
        #expect(refreshed.refreshToken == "refresh-token-2")
        #expect(refreshed.email == "cook@example.com")
    }

    @Test func rejectedRefreshTokenMeansSessionExpired() async {
        let stub = StubHTTPClient()
        stub.on("POST", "/v1/token", .fixture("auth_error_token_expired", status: 400))
        let creds = AuthCredentials(userID: "u", email: nil, idToken: "x", refreshToken: "bad", expiresAt: t0)
        await #expect(throws: ThermoWorksError.sessionExpired) {
            try await authenticator(stub).refresh(creds)
        }
    }
}

@Suite("Token manager")
struct TokenManagerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func manager(expiresIn: TimeInterval, stub: StubHTTPClient = .thermoWorksHappyPath(),
                         onRefresh: (@Sendable (AuthCredentials) -> Void)? = nil) -> TokenManager {
        let now = t0
        let creds = AuthCredentials(userID: "test-uid", email: nil, idToken: "id-token-1",
                                    refreshToken: "refresh-token-1", expiresAt: t0.addingTimeInterval(expiresIn))
        return TokenManager(credentials: creds, authenticator: ThermoWorksAuthenticator(http: stub, now: { now }),
                            now: { now }, onRefresh: onRefresh)
    }

    @Test func freshTokenIsReused() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        let tokens = manager(expiresIn: 3600, stub: stub)
        #expect(try await tokens.validIDToken() == "id-token-1")
        #expect(stub.requests(matching: "/v1/token").isEmpty)
    }

    @Test func tokenInsideLeewayIsRefreshedAndReported() async throws {
        let reported = Mutex<[AuthCredentials]>([])
        let tokens = manager(expiresIn: 30) { creds in reported.withLock { $0.append(creds) } }
        #expect(try await tokens.validIDToken() == "id-token-2")
        #expect(reported.withLock { $0.map(\.idToken) } == ["id-token-2"])
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let stub = StubHTTPClient.thermoWorksHappyPath()
        let tokens = manager(expiresIn: 0, stub: stub)
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await tokens.forceRefresh().idToken } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(results) == ["id-token-2"])
        #expect(stub.requests(matching: "/v1/token").count < 10)
    }
}
