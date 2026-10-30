import Foundation

/// Public Firebase web-client identifiers for ThermoWorks Cloud (as served to cloud.thermoworks.com).
/// Overridable so tests and future changes don't require code edits.
public struct ThermoWorksConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var appID: String
    public var referer: String
    public var firebaseHost: URL
    public var identityHost: URL
    public var secureTokenHost: URL
    public var firestoreHost: URL
    /// Refresh the ID token this long before it expires.
    public var tokenRefreshLeeway: TimeInterval

    public init(
        apiKey: String = "AIzaSyCf079iccUFc1k7VHdGXng22zXDy8Y3KEY",
        appID: String = "1:78998049458:web:b41e9d405d8c7de95eefab",
        referer: String = "https://cloud.thermoworks.com/",
        firebaseHost: URL = URL(string: "https://firebase.googleapis.com")!,
        identityHost: URL = URL(string: "https://identitytoolkit.googleapis.com")!,
        secureTokenHost: URL = URL(string: "https://securetoken.googleapis.com")!,
        firestoreHost: URL = URL(string: "https://firestore.googleapis.com")!,
        tokenRefreshLeeway: TimeInterval = 60
    ) {
        self.apiKey = apiKey
        self.appID = appID
        self.referer = referer
        self.firebaseHost = firebaseHost
        self.identityHost = identityHost
        self.secureTokenHost = secureTokenHost
        self.firestoreHost = firestoreHost
        self.tokenRefreshLeeway = tokenRefreshLeeway
    }

    public static let `default` = ThermoWorksConfiguration()
}

/// Firebase project details resolved from the web config endpoint.
public struct ThermoWorksProject: Sendable, Codable, Equatable {
    public var projectID: String
    public var storageBucket: String?

    public init(projectID: String, storageBucket: String?) {
        self.projectID = projectID
        self.storageBucket = storageBucket
    }

    /// `projects/{p}/databases/(default)/documents`
    var documentsRoot: String { "projects/\(projectID)/databases/(default)/documents" }
}
