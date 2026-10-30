import Foundation

public enum AuthFailureReason: Sendable, Equatable {
    case invalidEmail
    case emailNotFound
    case invalidPassword
    case invalidLoginCredentials
    case userDisabled
    case tooManyAttempts
    case other(String)

    /// Maps Firebase Auth error messages, e.g. `"INVALID_PASSWORD"` or `"TOO_MANY_ATTEMPTS_TRY_LATER : ..."`.
    init(firebaseMessage: String) {
        let code = firebaseMessage.split(separator: " ").first.map(String.init) ?? firebaseMessage
        switch code {
        case "INVALID_EMAIL": self = .invalidEmail
        case "EMAIL_NOT_FOUND": self = .emailNotFound
        case "INVALID_PASSWORD": self = .invalidPassword
        case "INVALID_LOGIN_CREDENTIALS": self = .invalidLoginCredentials
        case "USER_DISABLED": self = .userDisabled
        case "TOO_MANY_ATTEMPTS_TRY_LATER": self = .tooManyAttempts
        default: self = .other(firebaseMessage)
        }
    }
}

public enum ThermoWorksError: Error, Sendable, Equatable {
    case authenticationFailed(AuthFailureReason)
    /// The refresh token was rejected; the user must sign in again.
    case sessionExpired
    case notFound(String)
    case http(status: Int, body: String)
    case network(String)
    case decoding(String)
}

extension ThermoWorksError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            switch reason {
            case .invalidEmail: "That email address isn't valid."
            case .emailNotFound, .invalidPassword, .invalidLoginCredentials: "Incorrect email or password."
            case .userDisabled: "This ThermoWorks account is disabled."
            case .tooManyAttempts: "Too many attempts. Try again later."
            case .other(let message): "Sign-in failed: \(message)"
            }
        case .sessionExpired: "Your session expired. Please sign in again."
        case .notFound(let what): "\(what) not found."
        case .http(let status, _): "ThermoWorks Cloud returned an error (\(status))."
        case .network(let message): "Network error: \(message)"
        case .decoding(let message): "Unexpected response from ThermoWorks Cloud: \(message)"
        }
    }
}
