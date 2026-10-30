import Foundation

/// A Firestore REST document. See https://firebase.google.com/docs/firestore/reference/rest/v1/projects.databases.documents
public struct FirestoreDocument: Decodable, Sendable, Equatable {
    /// Full resource name: `projects/{p}/databases/(default)/documents/{path}`.
    public let name: String
    public let fields: [String: FirestoreValue]
    public let createTime: Date?
    public let updateTime: Date?

    public init(name: String, fields: [String: FirestoreValue], createTime: Date? = nil, updateTime: Date? = nil) {
        self.name = name
        self.fields = fields
        self.createTime = createTime
        self.updateTime = updateTime
    }

    private enum CodingKeys: String, CodingKey { case name, fields, createTime, updateTime }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        fields = try c.decodeIfPresent([String: FirestoreValue].self, forKey: .fields) ?? [:]
        createTime = try c.decodeIfPresent(String.self, forKey: .createTime).flatMap(FirestoreTimestamp.parse)
        updateTime = try c.decodeIfPresent(String.self, forKey: .updateTime).flatMap(FirestoreTimestamp.parse)
    }

    /// Path segments after `/documents/`, e.g. `["devices", "ABC123", "channels", "1"]`.
    public var pathSegments: [String] {
        guard let range = name.range(of: "/documents/") else { return [] }
        return name[range.upperBound...].split(separator: "/").map(String.init)
    }

    /// The last path segment (the document id).
    public var documentID: String { pathSegments.last ?? "" }

    public subscript(field: String) -> FirestoreValue? { fields[field] }
}

/// `GET .../documents/{collection}` response.
struct FirestoreListResponse: Decodable {
    let documents: [FirestoreDocument]?
    let nextPageToken: String?
}

/// One element of a `documents:runQuery` response stream.
struct FirestoreRunQueryElement: Decodable {
    let document: FirestoreDocument?
}

/// One element of a `documents:batchGet` response.
struct FirestoreBatchGetElement: Decodable {
    let found: FirestoreDocument?
    let missing: String?
}
