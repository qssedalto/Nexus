import SwiftUI
import NexusCore

/// iCloud networking is manual unless the user enables the separate scheduled
/// synchronization switch. Opening this view does not access the account.
@MainActor
struct ClipboardCloudSettingsView: View {
    @ObservedObject private var cloud = ClipboardCloudController.shared
    @State private var confirmLocalCacheRemoval = false
    @State private var showCloudEraseSheet = false
    @State private var cloudEraseConfirmation = ""

    var body: some View {
        Form {
            Section(localized("iCloud clipboard (user controlled)")) {
                Toggle(localized("Enable iCloud clipboard history sync"), isOn: $cloud.enabled)
                Toggle(localized("Automatically sync iCloud clipboard every 5 minutes"), isOn: $cloud.automaticSyncEnabled)
                    .disabled(!cloud.enabled || !cloud.containerConfigured)
                Text(localized("Automatic sync is off by default. If enabled, Nexus prepares at most 200 local history records per cycle and synchronizes only the CloudKit categories you have authorized. The private zone must first be created manually; turning off automatic sync stops future scheduled cycles."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("CloudKit requires a signed container and the selected data permissions. Manual sync works independently of the automatic schedule. Disabling either sync switch prevents future scheduled CloudKit requests."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(
                        localized(cloud.containerConfigured
                                  ? "CloudKit container configured"
                                  : "CloudKit container not configured for this build"),
                        systemImage: cloud.containerConfigured ? "checkmark.shield" : "lock.shield"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section(localized("Independent cloud data permissions")) {
                Toggle(localized("Include copied text in iCloud"),
                       isOn: $cloud.includeText).disabled(!cloud.enabled)
                Toggle(localized("Include file names and collection names"),
                       isOn: $cloud.includeNames).disabled(!cloud.enabled)
                Toggle(localized("Include full source file paths"),
                       isOn: $cloud.includePaths).disabled(!cloud.enabled)
                Toggle(localized("Include original clipboard images in iCloud (up to 8 MB)"),
                       isOn: $cloud.includeImages).disabled(!cloud.enabled)
                Toggle(localized("Include one small local file original in iCloud (up to 8 MB)"),
                       isOn: $cloud.includeFiles).disabled(!cloud.enabled)
                Text(localized("Original image and single-file transfers have independent permission switches, off by default. File transfer excludes folders, symlinks, cloud-only files and packages. Turning off permission cannot erase copies already uploaded."))
                    .font(.caption).foregroundStyle(.secondary)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(localized("Prepare and sync clipboard")) {
                HStack(spacing: 10) {
                    Button(localized("Prepare next local history page")) {
                        Task { await cloud.prepareLocalPage() }
                    }
                    .disabled(!cloud.enabled || cloud.running)
                    Button(localized("Create private iCloud zone")) {
                        Task { await cloud.setupPrivateZone() }
                    }
                    .disabled(!cloud.enabled || cloud.running || !cloud.containerConfigured)
                    Button(localized("Sync now")) {
                        Task { await cloud.syncNow() }
                    }
                    .disabled(!cloud.enabled || cloud.running || !cloud.containerConfigured)
                    Button(localized("Reset cloud change cursor")) {
                        cloud.resetServerCursor()
                    }
                    .disabled(!cloud.enabled || cloud.running)
                }
                Text(localized("Preparation only queues local data. Each click handles up to 200 history records; collections are included when their names are authorized. Sync now uploads pending changes and downloads one cloud change page."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(localized("Next history page offset:"))
                    Text(String(cloud.nextHistoryOffset)).monospacedDigit()
                    Spacer()
                    Text(localized("Pending local changes:"))
                    Text(String(cloud.pendingCount)).monospacedDigit()
                }
                .font(.caption)
                if let previous = cloud.lastSuccessfulSync {
                    HStack {
                        Text(localized("Last successful sync:"))
                        Text(
                            Date(timeIntervalSince1970:
                                TimeInterval(previous.finishedTimeMS) / 1_000),
                            style: .relative
                        )
                        Spacer()
                        Text("\(previous.uploaded) ↑ / \(previous.downloaded) ↓")
                            .monospacedDigit()
                        if previous.moreComing || previous.pending > 0 {
                            Text(localized("More changes pending"))
                        } else {
                            Text(localized("Synchronized at last run"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(cloud.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("iCloud clipboard data removal")) {
                Text(localized("Removing local cache preserves your original clipboard history. Erasing the private iCloud zone deletes Nexus clipboard cloud records for this Apple account, but another device can upload its own older copies if sync remains enabled there."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(localized("Clear local iCloud clipboard cache…"), role: .destructive) {
                        confirmLocalCacheRemoval = true
                    }
                    .disabled(cloud.running)
                    Button(localized("Erase Nexus clipboard data from iCloud…"),
                           role: .destructive) {
                        cloudEraseConfirmation = ""
                        showCloudEraseSheet = true
                    }
                    .disabled(cloud.running || !cloud.containerConfigured)
                }
            }

            Section(localized("Locally cached cloud history")) {
                HStack {
                    Text(localized("Remote records are a local preview, not a verified paste. Only plain text entries with authorized content may be copied again."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Refresh local cache")) { cloud.refreshLocalCache() }
                    Button(localized("Restore cached cloud history to local shelf")) {
                        Task { await cloud.restoreCachedHistory() }
                    }
                    .disabled(!cloud.enabled || cloud.running)
                }
                if cloud.enabled {
                    let remote = cloud.cachedRecords.filter {
                        !$0.isDeleted && $0.kind == .operation
                    }
                    if remote.isEmpty {
                        Text(localized("No cached cloud clipboard entries"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(remote, id: \.id) { record in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(record.id)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if case .operation(let operation)? = record.payload {
                                        Text(operation.text != nil && cloud.includeText
                                             ? String(operation.text!.prefix(120))
                                             : localized("Metadata only"))
                                            .font(.caption)
                                            .lineLimit(2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                                if case .operation(let operation)? = record.payload,
                                   operation.file != nil && cloud.includeFiles {
                                    Button(localized("Save remote file…")) {
                                        cloud.saveCachedRemoteFile(recordID: record.id)
                                    }
                                }
                                Button(localized("Copy text")) {
                                    cloud.copyRemoteText(record)
                                }
                                .disabled(!cloud.includeText || {
                                    if case .operation(let operation)? = record.payload {
                                        return operation.type != "text_copy" || operation.text == nil
                                    }
                                    return true
                                }())
                            }
                        }
                    }
                } else {
                    Text(localized("Enable iCloud clipboard consent to inspect its local cache"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
        .confirmationDialog(
            localized("Clear only the local iCloud clipboard cache?"),
            isPresented: $confirmLocalCacheRemoval
        ) {
            Button(localized("Clear local iCloud clipboard cache"), role: .destructive) {
                Task { await cloud.clearLocalCloudData() }
            }
        } message: {
            Text(localized("The local cloud outbox, cached records, cloud cursors and imported mirrors will be removed. Original locally copied entries are preserved; no network request is made."))
        }
        .sheet(isPresented: $showCloudEraseSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text(localized("Erase private Nexus iCloud clipboard zone"))
                    .font(.headline)
                Text(localized("This permanently deletes the entire dedicated NexusClipboard zone from the signed-in Apple account. Disable sync on other devices before proceeding to prevent re-upload. Your original local clipboard history is preserved."))
                    .font(.callout)
                TextField(localized("Type DELETE to confirm"), text: $cloudEraseConfirmation)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(localized("Cancel")) {
                        showCloudEraseSheet = false
                    }
                    Button(localized("Erase Nexus iCloud records"), role: .destructive) {
                        let confirmation = cloudEraseConfirmation
                        showCloudEraseSheet = false
                        Task { await cloud.erasePrivateNexusCloudZone(confirmation: confirmation) }
                    }
                    .disabled(cloudEraseConfirmation != "DELETE" || cloud.running)
                }
            }
            .padding(24)
            .frame(minWidth: 460, idealWidth: 520)
        }
    }
}
