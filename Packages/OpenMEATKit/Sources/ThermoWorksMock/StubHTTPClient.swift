import Foundation
import Synchronization
import ThermoWorksCloud

/// Routes requests to canned responses and records them. Parallel-test safe (no global state),
/// unlike a URLProtocol stub.
public final class StubHTTPClient: HTTPClient {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data

        public init(status: Int = 200, body: Data) {
            self.status = status
            self.body = body
        }

        public static func fixture(_ name: String, status: Int = 200) -> Response {
            Response(status: status, body: Fixtures.data(name))
        }

        public static func json(_ string: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(string.utf8))
        }
    }

    public struct Route: Sendable {
        let method: String
        /// Matched against `host + path`, e.g. `identitytoolkit.googleapis.com/v1/accounts:signInWithPassword`.
        let pathSuffix: String
        /// Responses served in order; the last one repeats.
        var responses: [Response]
    }

    private struct State {
        var routes: [Route] = []
        var requests: [URLRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func on(_ method: String, _ pathSuffix: String, _ responses: Response...) {
        state.withLock { $0.routes.append(Route(method: method, pathSuffix: pathSuffix, responses: responses)) }
    }

    public var requests: [URLRequest] { state.withLock { $0.requests } }

    public func requests(matching pathSuffix: String) -> [URLRequest] {
        requests.filter { Self.target($0).hasSuffix(pathSuffix) }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let target = Self.target(request)
        let method = request.httpMethod ?? "GET"
        let response: Response? = state.withLock { state in
            state.requests.append(request)
            guard let index = state.routes.lastIndex(where: { $0.method == method && target.hasSuffix($0.pathSuffix) }) else {
                return nil
            }
            let responses = state.routes[index].responses
            if responses.count > 1 { state.routes[index].responses.removeFirst() }
            return responses.first
        }
        guard let response else {
            throw ThermoWorksError.network("No stub for \(method) \(target)")
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (response.body, http)
    }

    /// `host + decoded path`, no query.
    static func target(_ request: URLRequest) -> String {
        guard let url = request.url else { return "" }
        return (url.host() ?? "") + (url.path(percentEncoded: false))
    }
}

public extension StubHTTPClient {
    /// A stub pre-wired with the happy-path ThermoWorks Cloud fixtures (project `tw-test`, one RFX probe).
    static func thermoWorksHappyPath() -> StubHTTPClient {
        let stub = StubHTTPClient()
        stub.on("GET", "/webConfig", .fixture("web_config"))
        stub.on("POST", "/v1/accounts:signInWithPassword", .fixture("auth_sign_in"))
        stub.on("POST", "/v1/token", .fixture("auth_refresh"))
        stub.on("GET", "/documents/users/test-uid", .fixture("user"))
        stub.on("POST", "/documents:runQuery", .fixture("devices_run_query"))
        stub.on("GET", "/documents/devices/RFX-TEST-1/channels", .fixture("channels_list"))
        stub.on("POST", "/documents:batchGet", .fixture("channels_batch_get"))
        return stub
    }
}

public enum Fixtures {
    /// Loads `Fixtures/<name>.json` from this module's bundle.
    public static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(name).json")
        }
        return data
    }
}
