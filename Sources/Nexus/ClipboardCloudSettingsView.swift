import SwiftUI
import NexusCore

/// A single, progressive sync workflow. No folder reads or uploads occur just
/// by opening this tab. Every destination and content type is opt-in.
@MainActor
struct ClipboardCloudSettingsView: View {
    @ObservedObject private var cloud = ClipboardCloudController.shared
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    @State private var confirmLocalCacheRemoval = false
    @State private var showFolderEraseSheet = false
    @State private var eraseConfirmation = ""
    @State private var pairingExpanded = false
    @State private var advancedExpanded = false

    private var hasSyncSelection: Bool {
        cloud.includeText || cloud.mirrorText || cloud.mirrorFiles || cloud.mirrorImages
            || cloud.includeNames || cloud.includePaths
    }

    private var readyToBegin: Bool {
        cloud.containerConfigured && cloud.pairingKeyConfigured
            && hasSyncSelection && !cloud.running
    }

    var body: some View {
        Form {
            Section(localized("Sync location")) {
                Picker(localized("Save in"), selection: Binding(
                    get: { cloud.storage },
                    set: { cloud.changeStorage(to: $0) }
                )) {
                    Text(localized("iCloud Drive")).tag(NexusSyncStorage.iCloudDrive)
                    Text(localized("Local folder")).tag(NexusSyncStorage.localFolder)
                }
                .pickerStyle(.segmented)

                Text(localized(cloud.storage == .iCloudDrive
                    ? "iCloud Drive keeps the folder available on your Apple devices. Select the existing NexusClipboardSync folder."
                    : "Local storage saves copies to the folder you choose. It does not automatically sync to other devices."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if cloud.containerConfigured {
                    LabeledContent(localized("Selected folder")) {
                        Text(cloud.selectedFolderPath)
                            .font(.caption)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    Button(localized("Change folder…")) {
                        cloud.chooseSyncFolder()
                    }
                } else {
                    Button(localized("Select folder…")) {
                        cloud.chooseSyncFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section(localized("Device pairing")) {
                if cloud.pairingKeyConfigured {
                    Label(localized("Encryption pairing key is ready"),
                          systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text(localized("Generate a key once to protect your synced data. Other devices use this same key."))
                        .font(.callout)
                    Button(localized("Generate pairing key")) {
                        cloud.generatePairingKey()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if cloud.pairingKeyConfigured {
                    DisclosureGroup(localized("View or enter pairing key"),
                                    isExpanded: $pairingExpanded) {
                        Button(localized("Show pairing key")) {
                            cloud.revealPairingKey()
                        }
                        if !cloud.revealedPairingKey.isEmpty {
                            Text(cloud.revealedPairingKey)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Button(localized("Copy pairing key")) {
                                cloud.copyPairingKey()
                            }
                            Button(localized("Hide pairing key")) {
                                cloud.hidePairingKey()
                            }
                        }
                        Text(localized("Only give the key to your own trusted devices."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    DisclosureGroup(localized("Already have a pairing key?")) {
                        SecureField(localized("Enter a 64-character pairing key"),
                                    text: $cloud.pairingKeyEntry)
                            .textFieldStyle(.roundedBorder)
                        Button(localized("Use existing key")) {
                            cloud.installPairingKey()
                        }
                        .disabled(cloud.pairingKeyEntry.isEmpty)
                    }
                }
            }

            Section(localized("What to synchronize")) {
                Toggle(localized("Clipboard text"), isOn: $cloud.includeText)
                Toggle(localized("Plain text files in selected folder"), isOn: $cloud.mirrorText)
                Toggle(localized("Copied file contents"), isOn: $cloud.mirrorFiles)
                Toggle(localized("Copied images"), isOn: $cloud.mirrorImages)
                Toggle(localized("Favorites and collection names"), isOn: $cloud.includeNames)
                Toggle(localized("Original file paths"), isOn: $cloud.includePaths)
                if !hasSyncSelection {
                    Text(localized("Choose at least one content type to start. Nothing is uploaded by default."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(localized("Visible folder copies are ordinary unencrypted files and may sync through iCloud Drive. Private pasteboard formats may not be recoverable."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(localized("Keyboard and mouse statistics are backed up separately in Keyboard and Mouse. Paste requests are kept in the local timeline."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("Sync status")) {
                if !cloud.containerConfigured {
                    Label(localized("First select a folder above."), systemImage: "folder")
                        .foregroundStyle(.secondary)
                } else if !cloud.pairingKeyConfigured {
                    Label(localized("Generate a pairing key above to continue."), systemImage: "key")
                        .foregroundStyle(.secondary)
                } else if !hasSyncSelection {
                    Label(localized("Select the content you want to synchronize."),
                          systemImage: "checklist")
                        .foregroundStyle(.secondary)
                } else if !cloud.enabled {
                    Button(localized("Start syncing")) {
                        Task { await cloud.startSync() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!readyToBegin)
                    Text(localized("Nexus will prepare the folder and synchronize in one step."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(localized("Sync automatically every 5 minutes"),
                           isOn: $cloud.automaticSyncEnabled)
                    Button(localized("Sync now")) {
                        Task { await cloud.syncIncludingLocalHistory() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cloud.running)
                    Button(localized("Stop syncing")) {
                        cloud.automaticSyncEnabled = false
                        cloud.enabled = false
                    }
                    .disabled(cloud.running)
                }
                if cloud.running {
                    ProgressView()
                        .controlSize(.small)
                }
                if cloud.mirrorPending > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(cloud.mirrorPending) " + localized("folder copies pending"))
                            Spacer()
                            Button(localized("Cancel folder copies")) {
                                cloud.cancelMirrorTasks()
                            }
                        }
                        if cloud.mirrorTotalBytes > 0 {
                            ProgressView(
                                value: Double(cloud.mirrorCompletedBytes),
                                total: Double(cloud.mirrorTotalBytes)
                            )
                            Text(
                                ByteCountFormatter.string(fromByteCount: cloud.mirrorCompletedBytes,
                                                          countStyle: .file)
                                + " / " +
                                ByteCountFormatter.string(fromByteCount: cloud.mirrorTotalBytes,
                                                          countStyle: .file)
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if !cloud.mirrorStatus.isEmpty {
                    Text(cloud.mirrorStatus).font(.caption)
                }
                Text(cloud.status)
                    .font(.caption)
                    .textSelection(.enabled)
                if let previous = cloud.lastSuccessfulSync {
                    HStack {
                        LabeledContent(localized("Written"), value: previous.uploaded.formatted())
                        LabeledContent(localized("Received records"), value: previous.downloaded.formatted())
                        LabeledContent(localized("Pending updates"), value: cloud.pendingCount.formatted())
                    }
                    LabeledContent(localized("Last sync"),
                                   value: Date(timeIntervalSince1970:
                                    TimeInterval(previous.finishedTimeMS) / 1000).formatted())
                }
                if cloud.enabled, !clipboard.historyEnabled || clipboard.paused {
                    Text(localized(clipboard.historyEnabled
                        ? "Clipboard history is paused. New copies are not added to sync."
                        : "Clipboard history is off. New copies are not added to sync."))
                        .font(.caption)
                    Button(localized(clipboard.historyEnabled ? "Resume clipboard history" : "Enable clipboard history monitoring")) {
                        if clipboard.historyEnabled { clipboard.paused = false }
                        else { clipboard.historyEnabled = true }
                    }
                }
            }

            if cloud.enabled {
                Section(localized("Synced clipboard history")) {
                    if cloud.visibleSyncedRecords.isEmpty {
                        Text(localized("No copied records matching your sync settings are available to preview."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DisclosureGroup(localized("Preview synced records")) {
                            ForEach(cloud.visibleSyncedRecords.prefix(20)) { record in
                                Label(syncedTitle(record), systemImage: record.kind == .collection ? "folder" : "doc.on.clipboard")
                                    .lineLimit(1)
                            }
                        }
                    }
                    if !cloud.cachedRecords.isEmpty {
                        Button(localized("Import synced records into local history")) {
                            Task { await cloud.restoreCachedHistory() }
                        }
                        .disabled(cloud.running)
                    }
                }
            }

            Section {
                DisclosureGroup(localized("Advanced sync tools"), isExpanded: $advancedExpanded) {
                    Button(localized("Prepare next 200 records")) {
                        Task { await cloud.prepareLocalPage() }
                    }
                    .disabled(!cloud.enabled || cloud.running)
                    Button(localized("Replay all folder changes")) {
                        cloud.resetServerCursor()
                    }
                    .disabled(!cloud.enabled || cloud.running)
                    Divider()
                    Button(localized("Clear local sync cache…"), role: .destructive) {
                        confirmLocalCacheRemoval = true
                    }
                    .disabled(cloud.running)
                    Button(localized("Delete synchronized Nexus folder records…"),
                           role: .destructive) {
                        eraseConfirmation = ""
                        showFolderEraseSheet = true
                    }
                    .disabled(cloud.running || !cloud.containerConfigured)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(localized("Clear only the local folder sync cache?"),
                            isPresented: $confirmLocalCacheRemoval,
                            titleVisibility: .visible) {
            Button(localized("Clear local cache"), role: .destructive) {
                Task { await cloud.clearLocalCloudData() }
            }
        } message: {
            Text(localized("Original local clipboard history is preserved. Files in the selected folder are not deleted."))
        }
        .sheet(isPresented: $showFolderEraseSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text(localized("Delete Nexus folder sync data"))
                    .font(.headline)
                Text(localized("Only Nexus encrypted sync records are deleted from the selected folder. Your other files and original clipboard history are preserved. Type DELETE to confirm."))
                    .font(.callout)
                TextField("DELETE", text: $eraseConfirmation)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(localized("Cancel")) { showFolderEraseSheet = false }
                    Spacer()
                    Button(localized("Delete sync records"), role: .destructive) {
                        let code = eraseConfirmation
                        showFolderEraseSheet = false
                        Task { await cloud.eraseSyncedFolderData(confirmation: code) }
                    }
                    .disabled(eraseConfirmation != "DELETE" || cloud.running)
                }
            }
            .padding(24)
            .frame(minWidth: 460, idealWidth: 540)
        }
    }

    private func syncedTitle(_ record: ClipboardCloudRecord) -> String {
        switch record.payload {
        case .collection(let collection): return collection.name
        case .operation(let operation):
            let preview = operation.text ?? operation.items.first?.name ?? operation.items.first?.path
            if let preview, !preview.isEmpty { return String(preview.prefix(120)) }
            if operation.type == "image_copy" { return localized("Image copy") }
            if operation.type == "text_copy" { return localized("Text copy") }
            return localized("File copy")
        default: return localized("Unknown")
        }
    }
}
