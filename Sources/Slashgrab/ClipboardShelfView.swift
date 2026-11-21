import AppKit
import SwiftUI
import SlashgrabCore

/// A lightweight, original bottom-shelf view of the existing SQLite timeline.
/// This does not install a second clipboard observer or retain image pixels.
struct ClipboardShelfView: View {
    @ObservedObject var appState: AppState
    @State private var search = ""
    @State private var filter: Category = .all
    @State private var message: String?
    @State private var confirmClear = false
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
            guard ["copy", "path_copy", "text_copy", "image_copy"].contains(operation.type) else { return false }
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
        // Pinned cards stay above recent entries; leave the chronological
        // order returned by SQLite untouched within each group.
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
        .onAppear { appState.refreshOperations() }
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
                .strokeBorder(accent.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button(localized("Copy again")) { copyAgain(operation) }
            Button(localized(isPinned ? "Unpin" : "Pin")) { togglePin(operation.id) }
            Button(localized("Delete from local history"), role: .destructive) {
                deleteLocally(operation.id)
            }
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

    private func copyAgain(_ operation: RecordedOperation) {
        if let text = operation.clipboardText, !text.isEmpty {
            appState.copyAgain(text)
            message = localized("Copied again")
            return
        }
        let urls = operation.items.compactMap { item -> NSURL? in
            guard let source = item.source, source.hasPrefix("/") else { return nil }
            return NSURL(fileURLWithPath: source)
        }
        guard !urls.isEmpty && urls.count == operation.items.count else {
            message = localized("Source file unavailable")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects(urls) {
            // The existing file clipboard observer, if enabled, will log it.
            message = localized("Copied again")
        } else {
            message = localized("Clipboard write failed")
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
