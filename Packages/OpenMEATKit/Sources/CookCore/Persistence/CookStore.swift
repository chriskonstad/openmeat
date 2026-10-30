import Foundation

/// Lightweight row for the history list.
public struct CookSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var probeLabels: [String]
    public var peakCelsius: Double?

    public init(_ cook: Cook) {
        id = cook.id
        title = cook.title
        startedAt = cook.startedAt
        endedAt = cook.endedAt
        probeLabels = cook.probes.filter { $0.role == .internal }.map(\.label)
        peakCelsius = cook.probes.filter { $0.role == .internal }
            .compactMap { cook.series[$0.key]?.map(\.celsius).max() }.max()
    }
}

public protocol CookStore: Sendable {
    func save(_ cook: Cook) async throws
    func load(id: UUID) async throws -> Cook
    /// Newest first.
    func summaries() async throws -> [CookSummary]
    func delete(id: UUID) async throws
}

public enum CookStoreError: Error, Equatable {
    case notFound(UUID)
}

/// One JSON file per cook plus a small summary file, in a directory (Application Support in the app).
public actor FileCookStore: CookStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    private func cookURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).cook.json") }
    private func summaryURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).summary.json") }

    public func save(_ cook: Cook) throws {
        try encoder.encode(cook).write(to: cookURL(cook.id), options: .atomic)
        try encoder.encode(CookSummary(cook)).write(to: summaryURL(cook.id), options: .atomic)
    }

    public func load(id: UUID) throws -> Cook {
        guard let data = try? Data(contentsOf: cookURL(id)) else { throw CookStoreError.notFound(id) }
        return try decoder.decode(Cook.self, from: data)
    }

    public func summaries() throws -> [CookSummary] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files.filter { $0.lastPathComponent.hasSuffix(".summary.json") }
            .compactMap { try? decoder.decode(CookSummary.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) throws {
        try? FileManager.default.removeItem(at: cookURL(id))
        try? FileManager.default.removeItem(at: summaryURL(id))
    }
}

public actor InMemoryCookStore: CookStore {
    private var cooks: [UUID: Cook] = [:]

    public init(_ cooks: [Cook] = []) {
        for cook in cooks { self.cooks[cook.id] = cook }
    }

    public func save(_ cook: Cook) { cooks[cook.id] = cook }

    public func load(id: UUID) throws -> Cook {
        guard let cook = cooks[id] else { throw CookStoreError.notFound(id) }
        return cook
    }

    public func summaries() -> [CookSummary] {
        cooks.values.map(CookSummary.init).sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) { cooks[id] = nil }
}
