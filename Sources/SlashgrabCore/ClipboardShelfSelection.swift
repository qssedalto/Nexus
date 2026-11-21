import Foundation

/// Keeps keyboard actions pointed at a card that is actually visible after
/// filtering, searching, switching collections or a background history refresh.
/// This pure helper does not read or change clipboard data or preferences.
public enum ClipboardShelfSelection {
    public static func visibleSelection(
        currentID: String?, visibleIDs: [String]
    ) -> String? {
        if let currentID, visibleIDs.contains(currentID) { return currentID }
        return visibleIDs.first
    }
}
