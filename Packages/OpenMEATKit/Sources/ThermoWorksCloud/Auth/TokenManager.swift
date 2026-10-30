import Foundation

/// Hands out valid ID tokens, refreshing at most once at a time when they near expiry.
public actor TokenManager {
    public private(set) var credentials: AuthCredentials
    private let authenticator: ThermoWorksAuthenticator
    private let now: @Sendable () -> Date
    private let onRefresh: (@Sendable (AuthCredentials) -> Void)?
    private var inFlightRefresh: Task<AuthCredentials, any Error>?

    /// - Parameter onRefresh: called with new credentials (e.g. to persist them in the Keychain).
    public init(
        credentials: AuthCredentials,
        authenticator: ThermoWorksAuthenticator,
        now: @escaping @Sendable () -> Date = Date.init,
        onRefresh: (@Sendable (AuthCredentials) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.authenticator = authenticator
        self.now = now
        self.onRefresh = onRefresh
    }

    public var userID: String { credentials.userID }

    public func validIDToken() async throws -> String {
        if !credentials.needsRefresh(at: now(), leeway: authenticator.configuration.tokenRefreshLeeway) {
            return credentials.idToken
        }
        return try await forceRefresh().idToken
    }

    /// Refreshes now (e.g. after a 401), coalescing concurrent callers onto one request.
    @discardableResult
    public func forceRefresh() async throws -> AuthCredentials {
        if let inFlightRefresh { return try await inFlightRefresh.value }
        let current = credentials
        let authenticator = authenticator
        let task = Task { try await authenticator.refresh(current) }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        let refreshed = try await task.value
        credentials = refreshed
        onRefresh?(refreshed)
        return refreshed
    }
}
