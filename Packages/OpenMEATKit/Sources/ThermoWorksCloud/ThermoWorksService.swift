import Foundation

/// Authenticated, read-only access to a user's ThermoWorks devices.
/// Implemented by `LiveThermoWorksService` (cloud) and `MockThermoWorksService` (simulator).
public protocol ThermoWorksService: Sendable {
    func currentUser() async throws -> TWUser
    func devices() async throws -> [TWDevice]
    /// Every channel of a device (used for discovery).
    func channels(forDevice serial: String) async throws -> [TWChannel]
    /// Specific channels in one round trip (used for polling). Missing channels are omitted.
    func channels(_ refs: [TWChannelRef]) async throws -> [TWChannel]
}

/// Firestore REST implementation. Docs: https://firebase.google.com/docs/firestore/reference/rest
public final class LiveThermoWorksService: ThermoWorksService {
    private let configuration: ThermoWorksConfiguration
    private let project: ThermoWorksProject
    private let tokens: TokenManager
    private let http: any HTTPClient

    public init(configuration: ThermoWorksConfiguration = .default, project: ThermoWorksProject,
                tokens: TokenManager, http: any HTTPClient) {
        self.configuration = configuration
        self.project = project
        self.tokens = tokens
        self.http = http
    }

    /// Resolves the project, signs in, and returns a ready service plus the credentials to persist.
    public static func signIn(
        email: String, password: String,
        configuration: ThermoWorksConfiguration = .default,
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        onRefresh: (@Sendable (AuthCredentials) -> Void)? = nil
    ) async throws -> (service: LiveThermoWorksService, project: ThermoWorksProject, credentials: AuthCredentials) {
        let authenticator = ThermoWorksAuthenticator(configuration: configuration, http: http, now: now)
        let project = try await authenticator.fetchProject()
        let credentials = try await authenticator.signIn(email: email, password: password)
        let tokens = TokenManager(credentials: credentials, authenticator: authenticator, now: now, onRefresh: onRefresh)
        let service = LiveThermoWorksService(configuration: configuration, project: project, tokens: tokens, http: http)
        return (service, project, credentials)
    }

    // MARK: ThermoWorksService

    public func currentUser() async throws -> TWUser {
        let uid = await tokens.userID
        let document: FirestoreDocument = try await get("users/\(uid)", notFound: "User")
        return TWUser(document: document)
    }

    public func devices() async throws -> [TWDevice] {
        let user = try await currentUser()
        guard let accountID = user.accountID else { return [] }
        let query: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "devices"]],
                "where": ["fieldFilter": [
                    "field": ["fieldPath": "accountId"],
                    "op": "EQUAL",
                    "value": ["stringValue": accountID],
                ]],
                "orderBy": [["field": ["fieldPath": "__name__"], "direction": "ASCENDING"]],
            ],
        ]
        let elements: [FirestoreRunQueryElement] = try await post("documents:runQuery", jsonObject: query)
        return elements.compactMap(\.document).map(TWDevice.init(document:))
    }

    public func channels(forDevice serial: String) async throws -> [TWChannel] {
        var channels: [TWChannel] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "50")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: FirestoreListResponse = try await get(
                "devices/\(serial)/channels", query: query, notFound: "Device \(serial)")
            channels += (page.documents ?? []).compactMap(TWChannel.init(document:))
            pageToken = page.nextPageToken
        } while pageToken != nil
        return channels.sorted { $0.ref.number.localizedStandardCompare($1.ref.number) == .orderedAscending }
    }

    public func channels(_ refs: [TWChannelRef]) async throws -> [TWChannel] {
        guard !refs.isEmpty else { return [] }
        let names = refs.map { "\(project.documentsRoot)/\($0.documentPath)" }
        let elements: [FirestoreBatchGetElement] = try await post("documents:batchGet", jsonObject: ["documents": names])
        return elements.compactMap(\.found).compactMap(TWChannel.init(document:))
    }

    // MARK: Requests

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        configuration.firestoreHost
            .appending(path: "v1/\(project.documentsRoot)")
            .appending(path: path)
            .appending(queryItems: [URLQueryItem(name: "key", value: configuration.apiKey)] + query)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], notFound: String) async throws -> T {
        try await send(try URLRequest.json("GET", url(path, query: query)), notFound: notFound)
    }

    private func post<T: Decodable>(_ path: String, jsonObject: [String: Any]) async throws -> T {
        // Firestore's `:runQuery`/`:batchGet` are custom methods on the documents root.
        let target = configuration.firestoreHost
            .appending(path: "v1/\(project.documentsRoot)")
            .deletingLastPathComponent()
            .appending(path: path)
            .appending(queryItems: [URLQueryItem(name: "key", value: configuration.apiKey)])
        var request = try URLRequest.json("POST", target)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        return try await send(request, notFound: path)
    }

    private func send<T: Decodable>(_ request: URLRequest, notFound: String, isRetry: Bool = false) async throws -> T {
        var authorized = request
        authorized.setValue("Bearer \(try await tokens.validIDToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.send(authorized)
        switch response.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw ThermoWorksError.decoding(String(describing: error))
            }
        case 401 where !isRetry:
            try await tokens.forceRefresh()
            return try await send(request, notFound: notFound, isRetry: true)
        case 404:
            throw ThermoWorksError.notFound(notFound)
        default:
            throw ThermoWorksError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}
