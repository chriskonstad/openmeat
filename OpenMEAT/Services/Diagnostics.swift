import Foundation
import os
import ThermoWorksCloud

/// Local-only diagnostics, written to `Library/Caches/Diagnostics` in the app container (never uploaded).
/// Used to learn the real shape of ThermoWorks data (SPEC §3.3) and to debug Live Activities on device:
///
///     xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
///         --domain-identifier org.openmeat.OpenMEAT --source Library/Caches/Diagnostics --destination ./diag
enum Diagnostics {
    static let logger = Logger(subsystem: "org.openmeat.OpenMEAT", category: "diagnostics")

    static var directory: URL {
        URL.cachesDirectory.appending(path: "Diagnostics")
    }

    /// Appends a timestamped line to `events.log` and the unified log.
    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        let url = directory.appending(path: "events.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Records Firestore response bodies (device and channel documents) for diagnostics. Auth endpoints
/// are never recorded, so no tokens or passwords touch disk.
struct RecordingHTTPClient: HTTPClient {
    let base: any HTTPClient

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(request)
        if let url = request.url, url.host() == "firestore.googleapis.com" {
            // Path after ".../documents" (e.g. "devices/<serial>/channels"), flattened into a file name.
            let path = url.path(percentEncoded: false)
            let tail = path.components(separatedBy: "/documents").last ?? url.lastPathComponent
            let name = tail.trimmingCharacters(in: CharacterSet(charactersIn: "/:"))
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "/", with: "_")
            let folder = Diagnostics.directory.appending(path: "firestore")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "\(name)-\(response.statusCode).json")
            try? data.write(to: file, options: .atomic)
        }
        return (data, response)
    }
}
