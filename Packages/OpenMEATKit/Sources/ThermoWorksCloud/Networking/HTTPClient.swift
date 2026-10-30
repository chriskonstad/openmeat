import Foundation

/// Minimal HTTP abstraction so the client can be exercised against stubs (see `StubHTTPClient`).
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ThermoWorksError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ThermoWorksError.network("Non-HTTP response")
        }
        return (data, http)
    }
}

extension URLRequest {
    static func json(_ method: String, _ url: URL, body: (any Encodable)? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}
