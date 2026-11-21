import SlashgrabCore
import SwiftUI

/// Displays only the title explicitly provided by the same copied URL's
/// pasteboard item. It does not issue any HTTP, WebKit or metadata requests.
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
                localTitle = nil
                let store = OperationStore.shared()
                let saved = await Task.detached(priority: .utility) {
                    try? store?.linkTitle(operationID: operationID)
                }.value
                guard !Task.isCancelled else { return }
                localTitle = saved
            }
    }
}
