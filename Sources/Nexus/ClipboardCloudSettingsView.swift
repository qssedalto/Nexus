import SwiftUI
import NexusCore

/// User-selected folder synchronization. Opening Settings never reads files,
/// uploads clipboard data, or starts a background task.
@MainActor
struct ClipboardCloudSettingsView: View {
    @ObservedObject private var cloud = ClipboardCloudController.shared
    @State private var confirmLocalCacheRemoval = false
    @State private var showFolderEraseSheet = false
    @State private var eraseConfirmation = ""

    var body: some View {
        Form {
            Section(localized("iCloud Drive clipboard folder")) {
                Button(localized("Choose NexusClipboardSync folder…")) {
                    cloud.chooseSyncFolder()
                }
                if cloud.containerConfigured {
                    Text(cloud.selectedFolderPath)
                        .font(.caption)
                        .textSelection(.enabled)
                } else {
                    Text(localized("Select your existing NexusClipboardSync folder in iCloud Drive. No developer subscription is needed."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(localized("Enable folder clipboard synchronization"), isOn: $cloud.enabled)
                    .disabled(!cloud.containerConfigured || !cloud.pairingKeyConfigured)
                Toggle(localized("Automatically synchronize every 5 minutes"), isOn: $cloud.automaticSyncEnabled)
                    .disabled(!cloud.enabled || !cloud.containerConfigured)
                Text(localized("Synchronization is off by default. Nexus only reads and writes the folder you select, when authorized. Apple Files synchronizes it between devices independently."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Folder sync v1 stores unencrypted JSON. Do not synchronize passwords, private text or sensitive file paths."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(localized("End-to-end encryption and device pairing")) {
                if cloud.pairingKeyConfigured {
                    Label(localized("Encryption key is stored in this device's Keychain"),
                          systemImage: "lock.shield")
                    Button(localized("Reveal pairing key for another device")) {
                        cloud.revealPairingKey()
                    }
                    if !cloud.revealedPairingKey.isEmpty {
                        Text(cloud.revealedPairingKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button(localized("Copy pairing key")) {
                                cloud.copyPairingKey()
                            }
                            Button(localized("Hide pairing key")) {
                                cloud.hidePairingKey()
                            }
                        }
                    }
                } else {
                    Button(localized("Generate encryption pairing key")) {
                        cloud.generatePairingKey()
                    }
                    Text(localized("Use the same 64-character key on each paired device. It is never stored in iCloud Drive."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField(localized("Enter a 64-character pairing key"), text: $cloud.pairingKeyEntry)
                    .textFieldStyle(.roundedBorder)
                Button(localized("Save entered key in Keychain")) {
                    cloud.installPairingKey()
                }
                .disabled(cloud.pairingKeyEntry.isEmpty)
                Text(localized("Never send this key through an untrusted channel. Losing it makes existing encrypted sync files unreadable."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(localized("Select which clipboard data may be synchronized")) {
                Toggle(localized("Include copied text"), isOn: $cloud.includeText)
                    .disabled(!cloud.enabled)
                Toggle(localized("Include names and collection titles"), isOn: $cloud.includeNames)
                    .disabled(!cloud.enabled)
                Toggle(localized("Include original local file paths"), isOn: $cloud.includePaths)
                    .disabled(!cloud.enabled)
                Text(localized("Original image and file bytes are not yet supported in folder synchronization. Paths on another device are descriptive only."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(localized("Folder synchronization controls")) {
                HStack(spacing: 12) {
                    Button(localized("Prepare selected folder")) {
                        Task { await cloud.prepareSelectedFolder() }
                    }
                    .disabled(!cloud.containerConfigured || !cloud.pairingKeyConfigured || cloud.running)
                    Button(localized("Prepare next 200 records")) {
                        Task { await cloud.prepareLocalPage() }
                    }
                    .disabled(!cloud.enabled || cloud.running)
                    Button(localized("Sync now")) {
                        Task { await cloud.syncNow() }
                    }
                    .disabled(!cloud.enabled || !cloud.containerConfigured || !cloud.pairingKeyConfigured || cloud.running)
                }
                HStack {
                    Button(localized("Import synced records into local history")) {
                        Task { await cloud.restoreCachedHistory() }
                    }
                    .disabled(!cloud.enabled || cloud.running)
                    Button(localized("Replay all folder changes")) {
                        cloud.resetServerCursor()
                    }
                    .disabled(!cloud.enabled || cloud.running)
                }
                HStack {
                    Text(localized("Pending updates"))
                    Text(String(cloud.pendingCount)).monospacedDigit()
                    Spacer()
                    if let previous = cloud.lastSuccessfulSync {
                        Text(Date(timeIntervalSince1970:
                            TimeInterval(previous.finishedTimeMS) / 1000), style: .relative)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(cloud.status)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Section(localized("Remove folder synchronization data")) {
                Text(localized("Local cache reset preserves independently saved history. Deleting synchronized records removes only Nexus-owned JSON files from the selected folder. Other devices can upload old records again."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(localized("Clear local sync cache…"), role: .destructive) {
                    confirmLocalCacheRemoval = true
                }
                .disabled(cloud.running)
                Button(localized("Delete synchronized Nexus folder records…"), role: .destructive) {
                    eraseConfirmation = ""
                    showFolderEraseSheet = true
                }
                .disabled(cloud.running || !cloud.containerConfigured)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(localized("Clear only the local folder sync cache?"),
                            isPresented: $confirmLocalCacheRemoval, titleVisibility: .visible) {
            Button(localized("Clear local cache"), role: .destructive) {
                Task { await cloud.clearLocalCloudData() }
            }
        } message: {
            Text(localized("Original local clipboard history is preserved. Files in iCloud Drive are not deleted."))
        }
        .sheet(isPresented: $showFolderEraseSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text(localized("Delete Nexus folder sync data"))
                    .font(.headline)
                Text(localized("This deletes Nexus-owned sync JSON documents in your selected folder, not the entire folder or unrelated iCloud Drive data. Disable synchronization on other devices first. Type DELETE to confirm."))
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
}
