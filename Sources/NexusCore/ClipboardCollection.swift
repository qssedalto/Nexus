import Foundation

/// A local-only named permanent clipboard collection. Entries reference
/// existing durable operation UUIDs; content is never copied into a second DB.
public struct ClipboardCollection: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let createdTimeMS: Int64

    public init(id: String, name: String, createdTimeMS: Int64) {
        self.id = id
        self.name = name
        self.createdTimeMS = createdTimeMS
    }
}
