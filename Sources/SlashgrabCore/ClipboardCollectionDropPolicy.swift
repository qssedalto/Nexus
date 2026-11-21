import Foundation

/// Accept card drag payloads from Nexus's currently loaded history only.
/// Clipboard bodies, image bytes, and external file paths never participate.
public enum ClipboardCollectionDropPolicy {
    public static func accepts(
        draggedID: String,
        loadedOperationIDs: Set<String>,
        targetCollectionID: String,
        availableCollectionIDs: Set<String>
    ) -> Bool {
        UUID(uuidString: draggedID) != nil &&
        loadedOperationIDs.contains(draggedID) &&
        availableCollectionIDs.contains(targetCollectionID)
    }
}
