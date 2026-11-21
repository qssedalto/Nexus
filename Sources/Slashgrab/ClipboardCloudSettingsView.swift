import SwiftUI
import SlashgrabCore

/// All cloud operations are manual. Simply opening this tab only reads
/// local UserDefaults/SQLite; it does not request an Apple account or network.
@MainActor
struct ClipboardCloudSettingsView: View {
    @ObservedObject private var cloud = ClipboardCloudController.shared

    var body: some View {
        Form {
            Section(localized("iCloud clipboard (manual opt-in)")) {
                Toggle(localized("Enable iCloud clipboard history sync"), isOn: $cloud.enabled)
                Text(localized("Off by default. Your current Nexus installation does not upload clipboard history until you explicitly configure a signed CloudKit container, authorize the categories below and press Sync Now."))
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
                Text(localized("Image pixels are never uploaded. Cloud copies of deleted or previously shared data require separate deletion; disabling consent prevents new uploads but cannot recall existing Apple iCloud copies."))
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
                Text(cloud.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("Locally cached cloud history")) {
                HStack {
                    Text(localized("Remote records are a local preview, not a verified paste. Only plain text entries with authorized content may be copied again."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Refresh local cache")) { cloud.refreshLocalCache() }
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
    }
}
