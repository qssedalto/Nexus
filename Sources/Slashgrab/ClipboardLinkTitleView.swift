import SlashgrabCore
import SwiftUI

/// Displays only locally stored, sanitized title metadata. An explicitly
/// authorized card action may separately retrieve a public HTTPS page title;
/// merely showing this view never issues an HTTP request.
struct ClipboardLinkTitleView: View {
    let operationID: String
    let host: String

    @State private var localTitle: String?

    var body: some View {
        Text(localTitle ?? host)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: operationID) {
                await reloadTitle()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("NexusRemoteLinkTitleUpdated")
            )) { note in
                guard (note.object as? String) == operationID else { return }
                Task { await reloadTitle() }
            }
    }

    private func reloadTitle() async {
        let store = OperationStore.shared()
        let saved = await Task.detached(priority: .utility) {
            try? store?.linkTitle(operationID: operationID)
        }.value
        guard !Task.isCancelled else { return }
        localTitle = saved
    }
}
