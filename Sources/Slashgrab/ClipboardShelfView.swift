import AppKit
import SwiftUI
import SlashgrabCore

/// A lightweight, original bottom-shelf view of the existing SQLite timeline.
/// This does not install a second clipboard observer or retain image pixels.
struct ClipboardShelfView: View {
    @ObservedObject var appState: AppState
    let onPasteRequested: () -> Void
    let onCloseRequested: () -> Void
    @State private var selectedOperationID: String?
    @FocusState private var shelfFocused: Bool
    @State private var search = ""
    @State private var filter: Category = .all
    @State private var message: String?
    @State private var confirmClear = false
    @State private var collections: [ClipboardCollection] = []
    @State private var selectedCollectionID = ""
    @State private var collectionMemberIDs: [String] = []
    @State private var newCollectionName = ""
    @State private var showingCreateCollection = false
    @State private var showingDeleteCollection = false
    @AppStorage("nexusPinnedClipboardOperationIDs") private var pinnedRaw = ""

    private enum Category: String, CaseIterable, Identifiable {
        case all, files, images, text, pinned
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return localized("All")
            case .files: return localized("Files")
            case .images: return localized("Images")
            case .text: return localized("Text")
            case .pinned: return localized("Pinned")
            }
        }
    }

    private var pinned: Set<String> {
        Set(pinnedRaw.split(separator: "\n").map(String.init))
    }

    private var operations: [RecordedOperation] {
        let pins = pinned
        let matches = appState.operations.filter { operation in
            guard ["copy", "path_copy", "text_copy", "image_copy", "drop_copy"].contains(operation.type) else { return false }
            if !selectedCollectionID.isEmpty && !collectionMemberIDs.contains(operation.id) { return false }
            let kind = operation.items.first?.kind
            switch filter {
            case .all: break
            case .files: if operation.type == "text_copy" || kind == "image" { return false }
            case .images: if kind != "image" { return false }
            case .text: if operation.type != "text_copy" { return false }
            case .pinned: if !pins.contains(operation.id) { return false }
            }
            guard !search.isEmpty else { return true }
            return (operation.clipboardText?.localizedCaseInsensitiveContains(search) ?? false)
                || operation.items.contains {
                    $0.name.localizedCaseInsensitiveContains(search)
                    || ($0.source?.localizedCaseInsensitiveContains(search) ?? false)
                }
        }
        if !selectedCollectionID.isEmpty {
            let positions = Dictionary(uniqueKeysWithValues: collectionMemberIDs.enumerated()
                .map { ($0.element, $0.offset) })
            return Array(matches.sorted {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }.prefix(100))
        }
        // Pinned cards stay above recent entries in the default history.
        return Array((matches.filter { pins.contains($0.id) }
                    + matches.filter { !pins.contains($0.id) }).prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Clipboard Shelf"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(localized("Search, pin and copy your recorded clipboard history."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    confirmClear = true
                } label: {
                    Label(localized("Clear unpinned local history"), systemImage: "trash")
                }
                Button {
                    appState.refreshOperations()
                } label: {
                    Label(localized("Refresh"), systemImage: "arrow.clockwise")
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(localized("Search clipboard"), text: $search)
                    .textFieldStyle(.plain)
                Spacer()
                Picker(localized("Category"), selection: $filter) {
                    ForEach(Category.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 152)
            }
            .padding(10)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Picker(localized("Permanent collection"), selection: $selectedCollectionID) {
                    Text(localized("All collections")).tag("")
                    ForEach(collections) { collection in
                        Text(collection.name).tag(collection.id)
                    }
                }
                .frame(maxWidth: 240)
                Button {
                    newCollectionName = ""
                    showingCreateCollection = true
                } label: { Image(systemName: "plus.circle") }
                    .help(localized("Create collection"))
                if !selectedCollectionID.isEmpty {
                    Button {
                        showingDeleteCollection = true
                    } label: { Image(systemName: "trash") }
                        .help(localized("Delete collection only"))
                }
                Spacer()
                Text(localized("Collections protect their entries from history cleanup."))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if operations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(localized("No clipboard history found"))
                        .fontWeight(.medium)
                    Text(localized("Enable file or text monitoring in Settings, then copy something."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 245)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 12) {
                        ForEach(operations) { operation in
                            card(for: operation)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .frame(height: 270)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(localized("Cards show metadata only for images and files; clipboard detection does not mean a file was pasted."))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(minWidth: 710, idealWidth: 890, minHeight: 355, idealHeight: 380)
        .background(.regularMaterial)
        .focusable()
        .focused($shelfFocused)
        .onAppear {
            appState.refreshOperations()
            loadCollections()
            shelfFocused = true
        }
        .onChange(of: appState.operations.map(\.id)) { _ in
            if selectedOperationID == nil { selectedOperationID = operations.first?.id }
        }
        .onMoveCommand { direction in
            let entries = operations
            guard !entries.isEmpty else { return }
            let index = entries.firstIndex(where: { $0.id == selectedOperationID }) ?? 0
            switch direction {
            case .left: selectedOperationID = entries[max(0, index - 1)].id
            case .right: selectedOperationID = entries[min(entries.count - 1, index + 1)].id
            default: break
            }
        }
        .onSubmit {
            if let selected = operations.first(where: { $0.id == selectedOperationID }) {
                requestPaste(selected, plainText: false)
            }
        }
        .onExitCommand(perform: onCloseRequested)
        .onChange(of: selectedCollectionID) { _ in loadCollectionMembers() }
        .alert(localized("Create permanent collection"), isPresented: $showingCreateCollection) {
            TextField(localized("Collection name"), text: $newCollectionName)
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Create")) { createCollection() }
        }
        .alert(localized("Delete this collection?"), isPresented: $showingDeleteCollection) {
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Delete collection"), role: .destructive) {
                deleteSelectedCollection()
            }
        } message: {
            Text(localized("The collection is removed; its saved clipboard operations remain in history."))
        }
        .confirmationDialog(localized("Delete all unpinned local copy history?"),
                            isPresented: $confirmClear) {
            Button(localized("Delete unpinned local history"), role: .destructive) {
                clearUnpinnedLocally()
            }
            Button(localized("Cancel"), role: .cancel) {}
        } message: {
            Text(localized("Pinned records are preserved. This does not delete anything previously uploaded to a remote server."))
        }
    }

    private func card(for operation: RecordedOperation) -> some View {
        let first = operation.items.first
        let kind = first?.kind ?? "text"
        let accent = color(for: kind)
        let isPinned = pinned.contains(operation.id)
        let label = first?.name ?? localized("Text")
        let snippet = operation.type == "text_copy"
            ? (operation.clipboardText ?? "")
            : (first?.source ?? localized("Unknown source"))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(categoryTitle(for: operation), systemImage: icon(for: kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Spacer()
                Button {
                    togglePin(operation.id)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? accent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(localized(isPinned ? "Unpin" : "Pin"))
            }
            .padding(.bottom, 2)

            Image(systemName: icon(for: kind))
                .font(.system(size: 31, weight: .ultraLight))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, minHeight: 57)

            Text(operation.type == "text_copy" ? localized("Copied text") : label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(snippet.isEmpty ? localized("Unknown source") : snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack {
                Text(Self.timestamp(operation.eventTimeMS ?? operation.detectedTimeMS))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    copyAgain(operation)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(localized("Copy again"))
            }
        }
        .padding(14)
        .frame(width: 202, height: 250)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    selectedOperationID == operation.id ? accent : accent.opacity(0.24),
                    lineWidth: selectedOperationID == operation.id ? 2.5 : 1
                )
        }
        .accessibilityElement(children: .contain)
        .onTapGesture {
            selectedOperationID = operation.id
        }
        .onTapGesture(count: 2) {
            requestPaste(operation, plainText: NSEvent.modifierFlags.contains(.control))
        }
        .contextMenu {
            Button(localized("Copy again")) { _ = copyAgain(operation) }
            Button(localized("Paste into previous app")) { requestPaste(operation, plainText: false) }
            Button(localized("Paste as plain text")) { requestPaste(operation, plainText: true) }
            Button(localized(isPinned ? "Unpin" : "Pin")) { togglePin(operation.id) }
            if !collections.isEmpty {
                Menu(localized("Add to collection")) {
                    ForEach(collections) { collection in
                        Button(collection.name) {
                            addToCollection(operation.id, collectionID: collection.id)
                        }
                    }
                }
            }
            if !selectedCollectionID.isEmpty {
                Button(localized("Remove from collection")) {
                    removeFromCurrentCollection(operation.id)
                }
                Button(localized("Move toward beginning")) {
                    moveInCurrentCollection(operation.id, earlier: true)
                }
                Button(localized("Move toward end")) {
                    moveInCurrentCollection(operation.id, earlier: false)
                }
            }
            Button(localized("Delete from local history"), role: .destructive) {
                deleteLocally(operation.id)
            }
        }
    }

    private func loadCollections() {
        let store = OperationStore.shared()
        Task {
            let records = await Task.detached(priority: .utility) {
                (try? store?.listCollections()) ?? []
            }.value
            collections = records
            if !selectedCollectionID.isEmpty &&
               !collections.contains(where: { $0.id == selectedCollectionID }) {
                selectedCollectionID = ""
            }
            loadCollectionMembers()
        }
    }

    private func loadCollectionMembers() {
        let current = selectedCollectionID
        guard !current.isEmpty else {
            collectionMemberIDs = []
            return
        }
        let store = OperationStore.shared()
        Task {
            let ids = await Task.detached(priority: .utility) {
                (try? store?.collectionOperationIDs(collectionID: current)) ?? []
            }.value
            guard selectedCollectionID == current else { return }
            collectionMemberIDs = ids
        }
    }

    private func createCollection() {
        let store = OperationStore.shared()
        let name = newCollectionName
        Task {
            let created = await Task.detached(priority: .utility) {
                try? store?.createCollection(named: name)
            }.value
            guard let created else {
                message = localized("Collection name is empty or already used")
                return
            }
            selectedCollectionID = created.id
            loadCollections()
        }
    }

    private func deleteSelectedCollection() {
        let id = selectedCollectionID
        guard !id.isEmpty else { return }
        let store = OperationStore.shared()
        Task {
            let result = await Task.detached(priority: .utility) {
                (try? store?.deleteCollection(id: id)) ?? false
            }.value
            if result {
                selectedCollectionID = ""
                loadCollections()
                message = localized("Collection removed; clipboard history preserved")
            } else {
                message = localized("Unable to delete collection")
            }
        }
    }

    private func addToCollection(_ operationID: String, collectionID: String) {
        let store = OperationStore.shared()
        Task {
            let success = await Task.detached(priority: .utility) {
                (try? store?.addOperation(id: operationID, toCollection: collectionID)) ?? false
            }.value
            if success {
                loadCollectionMembers()
                message = localized("Added to permanent collection")
            }
        }
    }

    private func removeFromCurrentCollection(_ operationID: String) {
        let collectionID = selectedCollectionID
        let store = OperationStore.shared()
        Task {
            _ = await Task.detached(priority: .utility) {
                try? store?.removeOperation(id: operationID, fromCollection: collectionID)
            }.value
            loadCollectionMembers()
        }
    }

    private func moveInCurrentCollection(_ operationID: String, earlier: Bool) {
        let collectionID = selectedCollectionID
        guard let position = collectionMemberIDs.firstIndex(of: operationID) else { return }
        let beforeID: String?
        if earlier {
            guard position > 0 else { return }
            beforeID = collectionMemberIDs[position - 1]
        } else {
            guard position < collectionMemberIDs.count - 1 else { return }
            // Moving before the entry after next moves the current one right.
            beforeID = position + 2 < collectionMemberIDs.count
                ? collectionMemberIDs[position + 2] : nil
        }
        let store = OperationStore.shared()
        Task {
            _ = await Task.detached(priority: .utility) {
                try? store?.moveOperation(id: operationID, before: beforeID, inCollection: collectionID)
            }.value
            loadCollectionMembers()
        }
    }

    private func deleteLocally(_ id: String) {
        let store = OperationStore.shared()
        Task {
            let deleted = await Task.detached(priority: .utility) {
                (try? store?.deleteOperation(id: id)) ?? false
            }.value
            if deleted {
                var remainingPins = pinned
                remainingPins.remove(id)
                pinnedRaw = remainingPins.sorted().joined(separator: "\n")
                appState.refreshOperations()
                message = localized("Local record deleted")
            } else {
                message = localized("Unable to delete local record")
            }
        }
    }

    private func clearUnpinnedLocally() {
        let keep = pinned
        let store = OperationStore.shared()
        Task {
            let removed = await Task.detached(priority: .utility) {
                var count = 0
                guard let store else { return -1 }
                do {
                    // Work is bounded to 1,000 deletions per SQLite transaction.
                    // Large histories may need additional passes, but the UI
                    // never blocks to recurse through files.
                    for _ in 0..<100 {
                        let batch = try store.pruneHistory(olderThan: Int64.max,
                                                           protectedIDs: keep,
                                                           maxDeletions: 1_000)
                        count += batch
                        if batch == 0 { break }
                    }
                    return count
                } catch {
                    return -1
                }
            }.value
            appState.refreshOperations()
            message = removed >= 0
                ? "\(removed) \(localized("local records deleted"))"
                : localized("Unable to clear local history")
        }
    }

    private func requestPaste(_ operation: RecordedOperation, plainText: Bool) {
        selectedOperationID = operation.id
        let didCopy: Bool
        if plainText {
            let content = operation.clipboardText ?? operation.items.compactMap(\.source).joined(separator: "\n")
            guard !content.isEmpty else {
                message = localized("Source file unavailable")
                return
            }
            didCopy = appState.copyAgain(content)
        } else {
            didCopy = copyAgain(operation)
        }
        if didCopy {
            onPasteRequested()
        }
        // The paste is a request to the previously active app, not proof
        // that a third-party target actually accepted the content.
    }

    @discardableResult
    private func copyAgain(_ operation: RecordedOperation) -> Bool {
        if let text = operation.clipboardText, !text.isEmpty {
            let copied = appState.copyAgain(text)
            message = localized(copied ? "Copied again" : "Clipboard write failed")
            return copied
        }
        let urls = operation.items.compactMap { item -> NSURL? in
            guard let source = item.source, source.hasPrefix("/") else { return nil }
            return NSURL(fileURLWithPath: source)
        }
        guard !urls.isEmpty && urls.count == operation.items.count else {
            message = localized("Source file unavailable")
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects(urls) {
            ClipboardMonitor.shared.ignoreCurrentChange()
            message = localized("Copied again")
            return true
        } else {
            message = localized("Clipboard write failed")
            return false
        }
    }

    private func togglePin(_ id: String) {
        var current = pinned
        if current.contains(id) { current.remove(id) }
        else { current.insert(id) }
        pinnedRaw = current.sorted().joined(separator: "\n")
    }

    private func categoryTitle(for operation: RecordedOperation) -> String {
        if operation.type == "text_copy" { return localized("Text") }
        if operation.type == "drop_copy" { return localized("Drag/drop copy") }
        let kind = operation.items.first?.kind
        if kind == "image" { return localized("Images") }
        if kind == "folder" { return localized("Folder") }
        return operation.type == "path_copy" ? localized("Path copy") : localized("Files")
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "image": return "photo"
        case "folder": return "folder.fill"
        case "package": return "shippingbox"
        case "archive": return "archivebox"
        case "video": return "film"
        case "document": return "doc.text"
        case "text": return "text.alignleft"
        default: return "doc"
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "image": return .pink
        case "folder", "package": return .blue
        case "archive": return .orange
        case "video": return .purple
        case "text": return .gray
        default: return .teal
        }
    }

    private static func timestamp(_ value: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(value) / 1_000))
    }
}
