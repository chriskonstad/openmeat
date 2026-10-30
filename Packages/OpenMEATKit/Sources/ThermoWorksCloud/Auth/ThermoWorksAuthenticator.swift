import Foundation

/// Tokens for a signed-in user. Persist in the Keychain.
public struct AuthCredentials: Sendable, Codable, Equatable {
    public var userID: String
    public var email: String?
    public var idToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(userID: String, email: String?, idToken: String, refreshToken: String, expiresAt: Date) {
        self.userID = userID
        self.email = email
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func needsRefresh(at now: Date, leeway: TimeInterval) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }
}

/// Stateless Firebase Auth + project-config calls.
/// Docs: https://firebase.google.com/docs/reference/rest/auth
public struct ThermoWorksAuthenticator: Sendable {
    public let configuration: ThermoWorksConfiguration
    private let http: any HTTPClient
    private let now: @Sendable () -> Date

    public init(
        configuration: ThermoWorksConfiguration = .default,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.http = http
        self.now = now
    }

    public func fetchProject() async throws -> ThermoWorksProject {
        let url = configuration.firebaseHost
            .appending(path: "v1alpha/projects/-/apps/\(configuration.appID)/webConfig")
        let request = try URLRequest.json("GET", url, headers: [
            "x-goog-api-key": configuration.apiKey,
            "Referer": configuration.referer,
        ])
        struct WebConfig: Decodable { let projectId: String; let storageBucket: String? }
        let config: WebConfig = try await decode(request)
        return ThermoWorksProject(projectID: config.projectId, storageBucket: config.storageBucket)
    }

    public func signIn(email: String, password: String) async throws -> AuthCredentials {
        struct Body: Encodable { let email: String; let password: String; let returnSecureToken = true }
        struct Response: Decodable {
            let localId: String
            let email: String?
            let idToken: String
            let refreshToken: String
            let expiresIn: String
        }
        let url = configuration.identityHost
            .appending(path: "v1/accounts:signInWithPassword")
            .appending(queryItems: [URLQueryItem(name: "key", value: configuration.apiKey)])
        let request = try URLRequest.json("POST", url, body: Body(email: email, password: password),
                                          headers: ["Referer": configuration.referer])
        let issuedAt = now()
        let r: Response = try await decode(request, authErrors: true)
        return AuthCredentials(
            userID: r.localId, email: r.email ?? email, idToken: r.idToken, refreshToken: r.refreshToken,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(r.expiresIn) ?? 3600)
        )
    }

    public func refresh(_ credentials: AuthCredentials) async throws -> AuthCredentials {
        struct Body: Encodable {
            let grant_type = "refresh_token"
            let refresh_token: String
        }
        struct Response: Decodable {
            let id_token: String
            let refresh_token: String
            let expires_in: String
            let user_id: String
        }
        let url = configuration.secureTokenHost
            .appending(path: "v1/token")
            .appending(queryItems: [URLQueryItem(name: "key", value: configuration.apiKey)])
        let request = try URLRequest.json("POST", url, body: Body(refresh_token: credentials.refreshToken),
                                          headers: ["Referer": configuration.referer])
        let issuedAt = now()
        let r: Response
        do {
            r = try await decode(request, authErrors: true)
        } catch ThermoWorksError.authenticationFailed {
            throw ThermoWorksError.sessionExpired
        }
        return AuthCredentials(
            userID: r.user_id, email: credentials.email, idToken: r.id_token, refreshToken: r.refresh_token,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(r.expires_in) ?? 3600)
        )
    }

    private func decode<T: Decodable>(_ request: URLRequest, authErrors: Bool = false) async throws -> T {
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if authErrors, response.statusCode == 400,
               let envelope = try? JSONDecoder().decode(FirebaseErrorEnvelope.self, from: data) {
                throw ThermoWorksError.authenticationFailed(AuthFailureReason(firebaseMessage: envelope.error.message))
            }
            throw ThermoWorksError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ThermoWorksError.decoding(String(describing: error))
        }
    }
}

struct FirebaseErrorEnvelope: Decodable {
    struct Body: Decodable { let code: Int; let message: String }
    let error: Body
}
