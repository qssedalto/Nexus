import AppKit
import SwiftUI
import SlashgrabCore
import UniformTypeIdentifiers

/// A lightweight, original bottom-shelf view of the existing SQLite timeline.
/// This does not install a second clipboard observer or retain image pixels.
struct ClipboardShelfView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    let onPasteRequested: () -> Void
    let onCloseRequested: () -> Void
    @State private var selectedOperationID: String?
    @FocusState private var shelfFocused: Bool
    @State private var search = ""
    @State private var sourceFilter = ""
    @State private var filter: Category = .all
    @State private var filterByDate = false
    @State private var startDate = Date().addingTimeInterval(-7 * 86_400)
    @State private var endDate = Date()
    @State private var searchedOperations: [RecordedOperation] = []
    @State private var searchGeneration = 0
    @State private var message: String?
    @State private var confirmClear = false
    @State private var collections: [ClipboardCollection] = []
    @State private var selectedCollectionID = ""
    @State private var collectionMemberIDs: [String] = []
    @State private var newCollectionName = ""
    @State private var showingCreateCollection = false
    @State private var showingDeleteCollection = false
    @AppStorage("nexusPinnedClipboardOperationIDs") private var pinnedRaw = ""
    @AppStorage("nexusClipboardFileThumbnailPreviews") private var filePreviewEnabled = false

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

    private var shouldQueryDatabase: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !sourceFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filterByDate || (filter != .all && filter != .pinned)
    }

    private var searchFingerprint: String {
        "\(search)|\(sourceFilter)|\(filter.rawValue)|\(filterByDate)|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)|\(searchGeneration)"
    }

    private var searchKind: ClipboardHistoryKind {
        switch filter {
        case .text: return .text
        case .files: return .files
        case .images: return .images
        case .all, .pinned: return .all
        }
    }

    private var searchStartMS: Int64 {
        filterByDate ? Int64(startDate.timeIntervalSince1970 * 1_000) : 0
    }

    private var searchEndMS: Int64 {
        // DatePicker is minute-precision; include the entire chosen end minute.
        filterByDate ? Int64(endDate.addingTimeInterval(60).timeIntervalSince1970 * 1_000)
                     : Int64.max
    }

    private var operations: [RecordedOperation] {
        let pins = pinned
        let candidates: [RecordedOperation]
        if shouldQueryDatabase && selectedCollectionID.isEmpty {
            // Keep pinned cards discoverable even when they are older than
            // a capped query. The final local filter still applies to them.
            var byID = Dictionary(uniqueKeysWithValues:
                searchedOperations.map { ($0.id, $0) })
            for entry in appState.shelfOperations where pins.contains(entry.id) {
                byID[entry.id] = entry
            }
            candidates = Array(byID.values)
        } else {
            candidates = appState.shelfOperations
        }

        let matches = candidates.filter { operation in
            guard ["copy", "path_copy", "text_copy", "image_copy", "drop_copy"].contains(operation.type) else { return false }
            if !selectedCollectionID.isEmpty && !collectionMemberIDs.contains(operation.id) { return false }
            let kind = operation.items.first?.kind
            switch filter {
            case .all: break
            case .files:
                if !["copy", "path_copy", "drop_copy"].contains(operation.type)
                    || !operation.items.contains(where: { $0.kind != "image" }) { return false }
            case .images:
                if operation.type != "image_copy"
                    && !operation.items.contains(where: { $0.kind == "image" }) { return false }
            case .text: if operation.type != "text_copy" { return false }
            case .pinned: if !pins.contains(operation.id) { return false }
            }
            if !sourceFilter.isEmpty &&
               !(operation.sourceApplication?.localizedCaseInsensitiveContains(sourceFilter) ?? false) {
                return false
            }
            let moment = operation.eventTimeMS ?? operation.detectedTimeMS
            if filterByDate && !(moment >= searchStartMS && moment < searchEndMS) {
                return false
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
        let ordered = matches.sorted {
            let lhs = $0.eventTimeMS ?? $0.detectedTimeMS
            let rhs = $1.eventTimeMS ?? $1.detectedTimeMS
            return lhs == rhs ? $0.id > $1.id : lhs > rhs
        }
        return Array((ordered.filter { pins.contains($0.id) }
                    + ordered.filter { !pins.contains($0.id) }).prefix(200))
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
                    refreshShelf()
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

            HStack(spacing: 10) {
                TextField(localized("Source application filter"), text: $sourceFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Toggle(localized("Filter by date"), isOn: $filterByDate)
                    .toggleStyle(.checkbox)
                if filterByDate {
                    DatePicker(localized("From"), selection: $startDate,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    DatePicker(localized("Through"), selection: $endDate,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                Spacer(minLength: 0)
            }
            .font(.caption)

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
                Text(localized(selectedCollectionID.isEmpty
                    ? "Collections protect their entries from history cleanup."
                    : "Drag cards to reorder this collection."))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !collections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text(localized("Drop a card into a collection:"))
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(collections) { collection in
                            Text(collection.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectedCollectionID == collection.id
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.primary.opacity(0.06),
                                    in: Capsule()
                                )
                                .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                    guard let provider = providers.first(where: {
                                        $0.canLoadObject(ofClass: NSString.self)
                                    }) else { return false }
                                    let targetID = collection.id
                                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                                        guard let draggedID = value as? String else { return }
                                        Task { @MainActor in
                                            let loaded = Set(appState.shelfOperations.map(\.id))
                                            let available = Set(collections.map(\.id))
                                            guard ClipboardCollectionDropPolicy.accepts(
                                                draggedID: draggedID,
                                                loadedOperationIDs: loaded,
                                                targetCollectionID: targetID,
                                                availableCollectionIDs: available
                                            ) else { return }
                                            addToCollection(draggedID, collectionID: targetID)
                                        }
                                    }
                                    return true
                                }
                        }
                    }
                }
                .frame(height: 34)
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
                .frame(maxWidth: .infinity, minHeight: 225)
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

            if shouldQueryDatabase && searchedOperations.count >= 200 {
                Text(localized("Showing the latest 200 matching records; narrow the search to find older ones."))
                    .font(.caption2).foregroundStyle(.secondary)
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
        .frame(minWidth: 710, idealWidth: 890, minHeight: 405, idealHeight: 455)
        .background(.regularMaterial)
        .focusable()
        .focused($shelfFocused)
        .onAppear {
            refreshShelf()
            loadCollections()
            shelfFocused = true
        }
        // Refresh only when an operation was actually committed to SQLite.
        // Unlike a timer or an observation callback, this cannot outrun the
        // background writer and miss the newly inserted clipboard event.
        .onChange(of: clipboard.savedRevision) { _ in
            refreshShelf()
        }
        .task(id: searchFingerprint) {
            guard shouldQueryDatabase else {
                searchedOperations = []
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(160))
                try Task.checkCancellation()
                let query = search
                let kind = searchKind
                let source = sourceFilter
                let lower = searchStartMS
                let upper = searchEndMS
                let store = OperationStore.shared()
                let found = await Task.detached(priority: .utility) {
                    try? store?.searchClipboard(
                        query: query, kind: kind, sourceApplication: source,
                        from: lower, to: upper, limit: 200
                    )
                }.value
                guard !Task.isCancelled else { return }
                searchedOperations = found ?? []
            } catch {
                // A newer query superseded this keystroke.
            }
        }
        .onChange(of: appState.shelfOperations.map(\.id)) { _ in
            if !operations.contains(where: { $0.id == selectedOperationID }) {
                selectedOperationID = operations.first?.id
            }
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
        let textPreview = operation.type == "text_copy"
            ? ClipboardTextPreview.classify(operation.clipboardText ?? "")
            : .plain
        let accent: Color = {
            switch textPreview {
            case .webLink: return .blue
            case .fencedCode: return .purple
            case .plain: return color(for: kind)
            }
        }()
        let previewSymbol: String = {
            switch textPreview {
            case .webLink: return "link"
            case .fencedCode: return "chevron.left.forwardslash.chevron.right"
            case .plain: return icon(for: kind)
            }
        }()
        let isPinned = pinned.contains(operation.id)
        let label = first?.name ?? localized("Text")
        let snippet = operation.type == "text_copy"
            ? (operation.clipboardText ?? "")
            : (first?.source ?? localized("Unknown source"))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(categoryTitle(for: operation), systemImage: previewSymbol)
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

            Group {
                if kind == "image" && operation.type == "image_copy" {
                    ClipboardImagePreview(operationID: operation.id)
                } else if filePreviewEnabled && operation.items.count == 1 &&
                            ["image", "document", "video"].contains(kind) {
                    ClipboardFilePreview(sourcePath: first?.source,
                                         fallbackIcon: icon(for: kind))
                } else {
                    Image(systemName: previewSymbol)
                        .font(.system(size: 31, weight: .ultraLight))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity, minHeight: 57)
                }
            }

            Text({
                switch textPreview {
                case .webLink(let host): return host
                case .fencedCode: return localized("Copied code")
                case .plain:
                    return operation.type == "text_copy" ? localized("Copied text") : label
                }
            }())
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            ClipboardRichTextExcerpt(
                operationID: operation.id,
                fallback: snippet.isEmpty ? localized("Unknown source") : snippet,
                monospaced: {
                    if case .fencedCode = textPreview { return true }
                    return false
                }()
            )

            Text(operation.sourceApplication ?? localized("Source application unknown"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

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
        .onDrag {
            // Export only an opaque operation ID, never clipboard content.
            NSItemProvider(object: operation.id as NSString)
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            guard !selectedCollectionID.isEmpty,
                  collectionMemberIDs.contains(operation.id),
                  let provider = providers.first(where: {
                      $0.canLoadObject(ofClass: NSString.self)
                  }) else { return false }
            let target = operation.id
            let collection = selectedCollectionID
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let dragged = value as? String else { return }
                Task { @MainActor in
                    guard selectedCollectionID == collection else { return }
                    reorderInCurrentCollection(dragged, before: target)
                }
            }
            return true
        }
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

    private func refreshShelf() {
        let requested = Array(pinned.union(collectionMemberIDs))
        appState.refreshShelfOperations(protectedIDs: requested)
        searchGeneration += 1
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
            refreshShelf()
            return
        }
        let store = OperationStore.shared()
        Task {
            let ids = await Task.detached(priority: .utility) {
                (try? store?.collectionOperationIDs(collectionID: current)) ?? []
            }.value
            guard selectedCollectionID == current else { return }
            collectionMemberIDs = ids
            refreshShelf()
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

    private func reorderInCurrentCollection(_ draggedID: String, before targetID: String) {
        let collectionID = selectedCollectionID
        guard !collectionID.isEmpty, draggedID != targetID,
              collectionMemberIDs.contains(draggedID),
              collectionMemberIDs.contains(targetID) else { return }
        let store = OperationStore.shared()
        Task {
            let changed = await Task.detached(priority: .utility) {
                (try? store?.moveOperation(id: draggedID,
                                          before: targetID,
                                          inCollection: collectionID)) ?? false
            }.value
            if changed {
                loadCollectionMembers()
            }
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
                // Stage a payload-free tombstone only when iCloud clipboard
                // sync was independently authorized and this entry was
                // previously included in its local journal.
                ClipboardCloudController.shared.recordLocalDeletion(id)
                var remainingPins = pinned
                remainingPins.remove(id)
                pinnedRaw = remainingPins.sorted().joined(separator: "\n")
                refreshShelf()
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
            refreshShelf()
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
        if operation.type == "image_copy" {
            guard let image = try? OperationStore.shared()?.imageContent(operationID: operation.id) else {
                message = localized("Original clipboard image unavailable")
                return false
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let copied = pasteboard.setData(
                image.data, forType: NSPasteboard.PasteboardType(image.pasteboardType)
            )
            if copied { ClipboardMonitor.shared.ignoreCurrentChange() }
            message = localized(copied ? "Copied again" : "Clipboard write failed")
            return copied
        }
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
        refreshShelf()
    }

    private func categoryTitle(for operation: RecordedOperation) -> String {
        if operation.type == "text_copy" {
            switch ClipboardTextPreview.classify(operation.clipboardText ?? "") {
            case .webLink: return localized("Links")
            case .fencedCode: return localized("Code")
            case .plain: return localized("Text")
            }
        }
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

private struct ClipboardImagePreview: View {
    let operationID: String
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 31, weight: .ultraLight))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 57, maxHeight: 77)
        .task(id: operationID) {
            let store = OperationStore.shared()
            let bytes = await Task.detached(priority: .utility) {
                try? store?.imageThumbnail(operationID: operationID)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = bytes.flatMap { NSImage(data: $0) }
        }
    }
}
