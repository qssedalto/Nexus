import Foundation

/// Privacy boundary between individual local input events and statistics
/// uploads. Ordinary character counts are never sent as per-keystroke rows.
/// Events are grouped in UTC buckets before the authenticated network call.
public enum InputUploadPrivacyPolicy {
    public enum PreparationError: Error, Sendable {
        case invalidEvent
        case countOverflow
    }

    private struct Bucket: Hashable {
        let category: String
        let name: String
        let timeMS: Int64
        let individualID: Int64?
    }

    public struct Plan: Sendable {
        public let events: [SyncInputEvent]
        private let sourceIDsByUploadID: [Int64: [Int64]]

        fileprivate init(events: [SyncInputEvent], sourceIDsByUploadID: [Int64: [Int64]]) {
            self.events = events
            self.sourceIDsByUploadID = sourceIDsByUploadID
        }

        /// Acknowledging one aggregate acknowledges exactly its constituent
        /// local rows, never unrelated rows or a server-supplied arbitrary ID.
        /// A malformed/duplicate acknowledgement fails closed.
        public func sourceIDs(forAcknowledgedUploadIDs acceptedIDs: [Int64]) -> [Int64]? {
            let unique = Set(acceptedIDs)
            guard unique.count == acceptedIDs.count,
                  !unique.isEmpty,
                  unique.isSubset(of: Set(events.map(\.id))) else { return nil }
            return acceptedIDs.flatMap { sourceIDsByUploadID[$0] ?? [] }
        }
    }

    public static func prepare(
        _ source: [SyncInputEvent], preciseNonTextEvents: Bool
    ) throws -> Plan {
        var grouped: [SyncInputEvent] = []
        var sourceIDs: [[Int64]] = []
        var bucketIndexes: [Bucket: Int] = [:]
        var seenIDs = Set<Int64>()

        for item in source {
            guard item.id >= 0, item.timeMS >= 0, item.count > 0,
                  !item.category.isEmpty, !item.name.isEmpty,
                  seenIDs.insert(item.id).inserted else {
                throw PreparationError.invalidEvent
            }

            // Even when the user enables precise non-text events, ordinary
            // character counts never use millisecond or individual timestamps.
            let isOrdinary = item.category == "ordinary" || item.name == "character_total"
            let resolution: Int64 = isOrdinary ? 3_600_000 : 60_000
            let timeMS: Int64
            let individualID: Int64?
            if !isOrdinary && preciseNonTextEvents {
                timeMS = item.timeMS
                individualID = item.id
            } else {
                timeMS = (item.timeMS / resolution) * resolution
                individualID = nil
            }
            let key = Bucket(
                category: item.category, name: item.name,
                timeMS: timeMS, individualID: individualID
            )
            if let index = bucketIndexes[key] {
                let existing = grouped[index]
                let (sum, overflow) = existing.count.addingReportingOverflow(item.count)
                guard !overflow else { throw PreparationError.countOverflow }
                grouped[index] = SyncInputEvent(
                    id: existing.id, timeMS: existing.timeMS,
                    category: existing.category, name: existing.name, count: sum
                )
                sourceIDs[index].append(item.id)
            } else {
                bucketIndexes[key] = grouped.count
                grouped.append(SyncInputEvent(
                    id: item.id, timeMS: timeMS, category: item.category,
                    name: item.name, count: item.count
                ))
                sourceIDs.append([item.id])
            }
        }

        let mapping = Dictionary(uniqueKeysWithValues: zip(grouped.map(\.id), sourceIDs))
        return Plan(events: grouped, sourceIDsByUploadID: mapping)
    }
}
