import AppKit
import SwiftUI
import NexusCore
import UniformTypeIdentifiers

/// A lightweight, original bottom-shelf view of the existing SQLite timeline.
/// This does not install a second clipboard observer or retain image pixels.
struct ClipboardShelfView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    let onPasteRequested: () -> Void
    let onCloseRequested: () -> Void
    @State private var selectedOperationID: String?
    @State private var detailOperation: RecordedOperation?
    @FocusState private var shelfFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var search = ""
    @State private var sourceFilter = ""
    @State private var filter: Category = .all
    @State private var filterByDate = false
    @State private var startDate = Date().addingTimeInterval(-7 * 86_400)
    @State private var endDate = Date()
    @State private var searchedOperations: [RecordedOperation] = []
    @State private var searchGeneration = 0
    @State private var searchPageCount = 1
    @State private var message: String?
    @State private var confirmClear = false
    @State private var clearingUnpinnedHistory = false
    @State private var collections: [ClipboardCollection] = []
    @State private var selectedCollectionID = ""
    @State private var collectionMemberIDs: [String] = []
    @State private var cardAccents: [String: ClipboardCardAccent] = [:]
    @State private var colorLoadGeneration = 0
    @State private var newCollectionName = ""
    @State private var renamedCollectionName = ""
    @State private var showingCreateCollection = false
    @State private var showingRenameCollection = false
    @State private var showingDeleteCollection = false
    @AppStorage("nexusPinnedClipboardOperationIDs") private var pinnedRaw = ""
    @AppStorage("nexusClipboardFileThumbnailPreviews") private var filePreviewEnabled = false
    @AppStorage("nexusClipboardRemoteTitlesEnabled") private var remoteTitlesEnabled = false
    @AppStorage("nexusClipboardCollectionSwitchModifier") private var collectionShortcutModifier = "command"

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
            || filterByDate || !selectedCollectionID.isEmpty
            || (filter != .all && filter != .pinned)
    }

    private var filterFingerprint: String {
        "\(search)|\(sourceFilter)|\(filter.rawValue)|\(filterByDate)|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)"
    }

    private var searchFingerprint: String {
        "\(filterFingerprint)|\(selectedCollectionID)|\(searchGeneration)|\(searchPageCount)"
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
        let collectionMembers = Set(collectionMemberIDs)
        // Mirror the SQLite query normalization so spaces or overlong
        // search fields do not hide valid results after the database finds them.
        let queryText = String(search.trimmingCharacters(
            in: .whitespacesAndNewlines).prefix(256))
        let sourceText = String(sourceFilter.trimmingCharacters(
            in: .whitespacesAndNewlines).prefix(128))
        let candidates: [RecordedOperation]
        if shouldQueryDatabase {
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
            if !selectedCollectionID.isEmpty && !collectionMembers.contains(operation.id) { return false }
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
            if !sourceText.isEmpty &&
               !(operation.sourceApplication?.localizedCaseInsensitiveContains(sourceText) ?? false) {
                return false
            }
            let moment = operation.eventTimeMS ?? operation.detectedTimeMS
            if filterByDate && !(moment >= searchStartMS && moment < searchEndMS) {
                return false
            }
            guard !queryText.isEmpty else { return true }
            return (operation.clipboardText?.localizedCaseInsensitiveContains(queryText) ?? false)
                || operation.items.contains {
                    $0.name.localizedCaseInsensitiveContains(queryText)
                    || ($0.source?.localizedCaseInsensitiveContains(queryText) ?? false)
                }
        }
        if !selectedCollectionID.isEmpty {
            let positions = Dictionary(uniqueKeysWithValues: collectionMemberIDs.enumerated()
                .map { ($0.element, $0.offset) })
            return Array(matches.sorted {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }.prefix(shouldQueryDatabase ? min(5_000, searchPageCount * 200) : 100))
        }
        let ordered = matches.sorted {
            let lhs = $0.eventTimeMS ?? $0.detectedTimeMS
            let rhs = $1.eventTimeMS ?? $1.detectedTimeMS
            return lhs == rhs ? $0.id > $1.id : lhs > rhs
        }
        let maximumCards = shouldQueryDatabase ? min(5_000, searchPageCount * 200) : 200
        return Array((ordered.filter { pins.contains($0.id) }
                    + ordered.filter { !pins.contains($0.id) }).prefix(maximumCards))
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            shelfContent
                .focusEffectDisabled()
                .onKeyPress { press in
                    handleShelfShortcut(press)
                }
        } else {
            shelfContent
        }
    }

    private var shelfContent: some View {
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
                .disabled(clearingUnpinnedHistory)
                if clearingUnpinnedHistory {
                    ProgressView()
                        .controlSize(.small)
                        .help(localized("Clearing local history…"))
                        .accessibilityLabel(localized("Clearing local history…"))
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
                    .focused($searchFocused)
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

            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        TextField(localized("Source application filter"), text: $sourceFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 190, idealWidth: 240, maxWidth: 300)
                        Toggle(localized("Filter by date"), isOn: $filterByDate)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(localized("Source application filter"), text: $sourceFilter)
                            .textFieldStyle(.roundedBorder)
                        Toggle(localized("Filter by date"), isOn: $filterByDate)
                            .toggleStyle(.checkbox)
                    }
                }
                if filterByDate {
                    HStack(spacing: 16) {
                        Text(localized("From")).foregroundStyle(.secondary)
                        DatePicker(localized("From"), selection: $startDate,
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .fixedSize()
                        Spacer(minLength: 12)
                    }
                    HStack(spacing: 16) {
                        Text(localized("Through")).foregroundStyle(.secondary)
                        DatePicker(localized("Through"), selection: $endDate,
                                   in: startDate..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .fixedSize()
                        Spacer(minLength: 12)
                    }
                }
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
                        renamedCollectionName = collections.first {
                            $0.id == selectedCollectionID
                        }?.name ?? ""
                        showingRenameCollection = true
                    } label: { Image(systemName: "pencil") }
                        .help(localized("Rename collection"))
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
                    Text(localized("Choose what Nexus may save, then copy again."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !clipboard.historyEnabled {
                        Toggle(localized("Enable clipboard history"), isOn: $clipboard.historyEnabled)
                            .toggleStyle(.checkbox)
                    }
                    HStack(spacing: 20) {
                        Toggle(localized("Record copied text"), isOn: $clipboard.textEnabled)
                            .toggleStyle(.checkbox)
                        Toggle(localized("Record copied files"), isOn: $clipboard.enabled)
                            .toggleStyle(.checkbox)
                        Toggle(localized("Record screenshots"), isOn: $clipboard.imageEnabled)
                            .toggleStyle(.checkbox)
                    }
                    .disabled(!clipboard.historyEnabled)
                    .font(.caption)
                    Text(localized("Clipboard content is stored on this Mac. Cloud upload requires separate permission."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 225)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(operations) { operation in
                            card(for: operation)
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if shouldQueryDatabase
                && searchedOperations.count >= searchPageCount * 200 {
                HStack {
                    Text("\(searchedOperations.count) " + localized("matching records loaded"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if searchPageCount < 25 {
                        Button(localized("Load 200 older matching records")) {
                            searchPageCount += 1
                        }
                        .font(.caption)
                    }
                }
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
        .frame(minWidth: 820, idealWidth: 1080, minHeight: 580, idealHeight: 680)
        .background(.regularMaterial)
        .focusable()
        .focused($shelfFocused)
        .onAppear {
            refreshShelf()
            loadCollections()
            selectedOperationID = ClipboardShelfSelection.visibleSelection(
                currentID: selectedOperationID, visibleIDs: operations.map(\.id)
            )
            shelfFocused = true
        }
        // Refresh only when an operation was actually committed to SQLite.
        // Unlike a timer or an observation callback, this cannot outrun the
        // background writer and miss the newly inserted clipboard event.
        .onChange(of: clipboard.savedRevision) { _ in
            refreshShelf()
        }
        .sheet(item: $detailOperation) { operation in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(categoryTitle(for: operation)).font(.title3.weight(.semibold))
                    Text(operation.clipboardText ?? operation.items.compactMap(\.source).joined(separator: "\n"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(localized("The foreground app at detection time may differ from the actual copy source."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(localized("Copy again")) { _ = copyAgain(operation) }
                }
                .padding(22)
            }
            .frame(minWidth: 480, minHeight: 300)
        }
        .onChange(of: filterFingerprint) { _ in searchPageCount = 1 }
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
                let collectionID = selectedCollectionID
                let lower = searchStartMS
                let upper = searchEndMS
                let store = OperationStore.shared()
                let pageCount = min(25, searchPageCount)
                let found = await Task.detached(priority: .utility) {
                    var accumulated: [RecordedOperation] = []
                    for page in 0..<pageCount {
                        if Task.isCancelled { break }
                        let batch = (try? store?.searchClipboard(
                            query: query, kind: kind, sourceApplication: source,
                            from: lower, to: upper, limit: 200,
                            offset: page * 200, collectionID: collectionID
                        )) ?? []
                        accumulated.append(contentsOf: batch)
                        if batch.count < 200 { break }
                    }
                    return accumulated
                }.value
                guard !Task.isCancelled else { return }
                searchedOperations = found
                loadCardAccents(for: Array(Set(
                    appState.shelfOperations.map(\.id) + found.map(\.id)
                )))
            } catch {
                // A newer query superseded this keystroke.
            }
        }
        .onChange(of: appState.shelfOperations.map(\.id)) { _ in
            loadCardAccents(for: Array(Set(
                appState.shelfOperations.map(\.id) + searchedOperations.map(\.id)
            )))
        }
        .onChange(of: operations.map(\.id)) { visibleIDs in
            selectedOperationID = ClipboardShelfSelection.visibleSelection(
                currentID: selectedOperationID, visibleIDs: visibleIDs
            )
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
        .onChange(of: selectedCollectionID) { _ in
            searchedOperations = []
            searchPageCount = 1
            loadCollectionMembers()
        }
        .alert(localized("Create permanent collection"), isPresented: $showingCreateCollection) {
            TextField(localized("Collection name"), text: $newCollectionName)
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Create")) { createCollection() }
        }
        .alert(localized("Rename permanent collection"), isPresented: $showingRenameCollection) {
            TextField(localized("Collection name"), text: $renamedCollectionName)
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Rename")) { renameSelectedCollection() }
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
            if let marked = cardAccents[operation.id] { return color(for: marked) }
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
                if cardAccents[operation.id] != nil {
                    Circle()
                        .fill(accent)
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(localized("Custom card color"))
                }
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

            if case .webLink(let host) = textPreview {
                ClipboardLinkTitleView(operationID: operation.id, host: host)
            } else {
                Text({
                    switch textPreview {
                    case .fencedCode: return localized("Copied code")
                    case .plain:
                        return operation.type == "text_copy" ? localized("Copied text") : label
                    case .webLink: return label
                    }
                }())
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .fencedCode = textPreview {
                ClipboardSyntaxExcerpt(source: snippet)
            } else {
                ClipboardRichTextExcerpt(
                    operationID: operation.id,
                    fallback: snippet.isEmpty ? localized("Unknown source") : snippet,
                    monospaced: false
                )
            }

            ClipboardSourceAppBadge(operation: operation)

            Spacer(minLength: 0)

            HStack {
                Text(Self.timestamp(operation.eventTimeMS ?? operation.detectedTimeMS))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(localized("Details")) { detailOperation = operation }
                    .buttonStyle(.borderless)
                Button { _ = copyAgain(operation) } label: {
                    Label(localized("Copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(localized("Copy again"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 300)
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
            detailOperation = operation
        }
        .contextMenu {
            Button(localized("Copy again")) { _ = copyAgain(operation) }
            if remoteTitlesEnabled,
               case .webLink = textPreview,
               let copiedText = operation.clipboardText {
                Button(localized("Fetch website title once")) {
                    Task {
                        guard remoteTitlesEnabled else { return }
                        do {
                            guard let title = try await ClipboardRemoteWebTitleFetcher.fetch(
                                from: copiedText
                            ) else {
                                if remoteTitlesEnabled {
                                    message = localized("Website title unavailable")
                                }
                                return
                            }
                            // Revocation during HTTP transfer must not create
                            // new retained website metadata.
                            guard remoteTitlesEnabled,
                                  let store = OperationStore.shared() else { return }
                            try store.recordLinkTitle(
                                operationID: operation.id, title: title,
                                expectedCopiedText: copiedText
                            )
                            NotificationCenter.default.post(
                                name: Notification.Name("NexusRemoteLinkTitleUpdated"),
                                object: operation.id
                            )
                            message = localized("Website title saved locally")
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
            }
            Button(localized("Paste into previous app")) { requestPaste(operation, plainText: false) }
            Button(localized("Paste as plain text")) { requestPaste(operation, plainText: true) }
            Button(localized(isPinned ? "Unpin" : "Pin")) { togglePin(operation.id) }
            Menu(localized("Mark card color")) {
                ForEach(ClipboardCardAccent.allCases, id: \.rawValue) { choice in
                    Button {
                        setCardAccent(choice, operationID: operation.id)
                    } label: {
                        Label(localized(choice.title),
                              systemImage: (cardAccents[operation.id] ?? .automatic) == choice
                                  ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
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

    /// Scoped to the focused clipboard panel, not a second system-wide
    /// hotkey. 0 selects all history; 1–9 follow the displayed collection
    /// order. The modifier pair is user-configurable in Nexus Settings.
    @available(macOS 14.0, *)
    private func handleShelfShortcut(_ press: KeyPress) -> KeyPress.Result {
        let hasCommand = press.modifiers.contains(.command)
        let hasControl = press.modifiers.contains(.control)
        let hasOption = press.modifiers.contains(.option)
        let hasShift = press.modifiers.contains(.shift)
        if hasCommand && !hasControl && !hasOption && !hasShift,
           press.characters.lowercased() == "f" {
            searchFocused = true
            return .handled
        }
        let mode = ClipboardCollectionSwitchModifier(
            rawValue: collectionShortcutModifier
        ) ?? .command
        let matches: Bool
        switch mode {
        case .command:
            matches = hasCommand && !hasControl && !hasOption && !hasShift
        case .controlOption:
            matches = hasControl && hasOption && !hasCommand && !hasShift
        }
        guard matches,
              let id = ClipboardCollectionShortcut.target(
                for: press.characters, collectionIDs: collections.map(\.id)
              ) else { return .ignored }
        selectedCollectionID = id
        selectedOperationID = nil
        shelfFocused = true
        return .handled
    }

    private func loadCardAccents(for ids: [String]) {
        let keys = Array(Set(ids)).sorted().prefix(5_000)
        let store = OperationStore.shared()
        colorLoadGeneration += 1
        let generation = colorLoadGeneration
        Task {
            let loaded = await Task.detached(priority: .utility) {
                var colors: [String: ClipboardCardAccent] = [:]
                guard let store else { return colors }
                for offset in stride(from: 0, to: keys.count, by: 500) {
                    let batch = Array(keys[offset..<min(keys.count, offset + 500)])
                    if let found = try? store.cardAccents(operationIDs: batch) {
                        colors.merge(found) { _, incoming in incoming }
                    }
                }
                return colors
            }.value
            guard generation == colorLoadGeneration else { return }
            cardAccents = loaded
        }
    }

    private func setCardAccent(
        _ accent: ClipboardCardAccent, operationID: String
    ) {
        guard let store = OperationStore.shared() else { return }
        // Prevent an older background tag read from undoing this click.
        colorLoadGeneration += 1
        Task {
            let saved = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try store.setCardAccent(accent, operationID: operationID)
                    return true
                } catch {
                    return false
                }
            }.value
            if saved {
                if accent == .automatic {
                    cardAccents.removeValue(forKey: operationID)
                } else {
                    cardAccents[operationID] = accent
                }
            } else {
                message = localized("Unable to update card color")
            }
        }
    }

    private func refreshShelf() {
        // Display at most 100 cards for an unfiltered collection, preserving
        // their deliberate order even if many unrelated history rows exist.
        let collectionIDs = selectedCollectionID.isEmpty
            ? [] : Array(collectionMemberIDs.prefix(100))
        let requested = collectionIDs + pinned.sorted()
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

    private func renameSelectedCollection() {
        let id = selectedCollectionID
        let name = renamedCollectionName
        guard !id.isEmpty else { return }
        let store = OperationStore.shared()
        Task {
            let changed = await Task.detached(priority: .utility) {
                (try? store?.renameCollection(id: id, to: name)) ?? false
            }.value
            if changed {
                loadCollections()
                message = localized("Collection renamed")
            } else {
                message = localized("Unable to rename collection")
            }
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
        guard !clearingUnpinnedHistory else { return }
        clearingUnpinnedHistory = true
        let keep = pinned
        // Snapshot the time of the user's explicit action. Copies made while
        // the cleanup runs must not be swept up by the next deletion batch.
        let cutoffMS = Int64(Date().timeIntervalSince1970 * 1_000)
        let store = OperationStore.shared()
        Task {
            let removed = await Task.detached(priority: .utility) { () async -> Int in
                guard let store else { return -1 }
                do {
                    return try await store.clearUnpinnedClipboardHistory(
                        olderThan: cutoffMS,
                        protectedIDs: keep
                    )
                } catch {
                    return -1
                }
            }.value
            clearingUnpinnedHistory = false
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
        if let error = ClipboardRecordRestorer.restore(operation) {
            message = error
            return false
        } else {
            appState.clipboardCopyDidSucceed()
            message = localized("Copied again")
            return true
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

    private func color(for accent: ClipboardCardAccent) -> Color {
        switch accent {
        case .automatic: return .secondary
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
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
