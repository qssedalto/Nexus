import NexusMobileCore
import SwiftUI
import UniformTypeIdentifiers

/// Adaptive iPhone/iPad UI with one explicit clipboard read button. It never
/// attempts unsupported iOS background clipboard observation or auto-paste.
struct MobileHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cloud = MobileClipboardController()
    @State private var collectionName = ""
    @State private var showCreateCollection = false
    @State private var search = ""
    @State private var showLocalCloudClear = false
    @State private var showCloudEraseSheet = false
    @State private var cloudEraseConfirmation = ""
    @State private var showFileExporter = false
    @State private var fileExport: NexusCloudFileDocument?
    @State private var fileExportName = "NexusFile"

    private var collections: [ClipboardCloudRecord] {
        cloud.records.filter { !$0.isDeleted && $0.kind == .collection }
    }

    private var localItems: [MobileLocalClipboardEntry] {
        cloud.localEntries.filter {
            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
        }
    }

    private var items: [ClipboardCloudRecord] {
        let localIDs = Set(cloud.localEntries.map {
            ClipboardCloudRecord.operationID($0.id)
        })
        return cloud.records.filter { record in
            guard !record.isDeleted, record.kind == .operation,
                  !localIDs.contains(record.id) else { return false }
            guard !search.isEmpty else { return true }
            if case .operation(let operation)? = record.payload {
                return operation.text?.localizedCaseInsensitiveContains(search) == true
                    || operation.items.contains {
                        $0.name?.localizedCaseInsensitiveContains(search) == true
                    }
            }
            return false
        }
    }

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)
                    ], spacing: 12) {
                        ForEach(localItems) { item in
                            localHistoryCard(item)
                        }
                        ForEach(items, id: \.id) { item in
                            historyCard(item)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Clipboard History")
                .searchable(text: $search, prompt: "Search cached text and names")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            cloud.importClipboardText()
                        } label: {
                            Label("Import clipboard", systemImage: "doc.on.clipboard")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("Clipboard is read only when Import clipboard is tapped. No background access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(.thinMaterial)
                }
            }
            .tabItem { Label("History", systemImage: "clock") }

            NavigationStack {
                List {
                    ForEach(collections, id: \.id) { collection in
                        HStack {
                            if case .collection(let info)? = collection.payload {
                                Text(info.name)
                            } else {
                                Text("Collection")
                            }
                            Spacer()
                            Button(role: .destructive) {
                                cloud.deleteLocalAndCloud(collection)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .navigationTitle("Permanent Collections")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCreateCollection = true
                        } label: { Label("New collection", systemImage: "plus") }
                    }
                }
                .alert("Create collection", isPresented: $showCreateCollection) {
                    TextField("Collection name", text: $collectionName)
                    Button("Cancel", role: .cancel) {}
                    Button("Create") {
                        cloud.createCollection(named: collectionName)
                        collectionName = ""
                    }
                }
            }
            .tabItem { Label("Collections", systemImage: "pin") }

            NavigationStack {
                Form {
                    Section("iCloud clipboard privacy") {
                        Toggle("Enable iCloud clipboard sync", isOn: $cloud.cloudEnabled)
                        Toggle("Sync iCloud clipboard when Nexus becomes active",
                               isOn: $cloud.foregroundSyncEnabled)
                            .disabled(!cloud.cloudEnabled || !cloud.containerConfigured)
                        Text("Foreground sync is optional and checks at most once every 5 minutes. It uses your selected iCloud permissions and never reads another app's clipboard. Create the private iCloud zone manually before enabling.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Include clipboard text", isOn: $cloud.includeText)
                            .disabled(!cloud.cloudEnabled)
                        Toggle("Include file and collection names", isOn: $cloud.includeNames)
                            .disabled(!cloud.cloudEnabled)
                        Toggle("Include file paths", isOn: $cloud.includePaths)
                            .disabled(!cloud.cloudEnabled)
                        Toggle("Include original clipboard images (up to 8 MB)",
                               isOn: $cloud.includeImages)
                            .disabled(!cloud.cloudEnabled)
                        Toggle("Include one small original file (up to 8 MB)",
                               isOn: $cloud.includeFiles)
                            .disabled(!cloud.cloudEnabled)
                        Text("Image and single-file originals use independent iCloud permissions. Files are exported only when you request it; Nexus does not inspect the clipboard in the background.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Manual synchronization") {
                        LabeledContent("CloudKit container", value:
                            cloud.containerConfigured
                                ? String(localized: "Configured")
                                : String(localized: "Not configured"))
                        Button("Create private iCloud zone") {
                            Task { await cloud.setupPrivateZone() }
                        }
                        .disabled(!cloud.cloudEnabled || !cloud.containerConfigured || cloud.running)
                        Button("Sync now") {
                            Task { await cloud.syncNow() }
                        }
                        .disabled(!cloud.cloudEnabled || !cloud.containerConfigured || cloud.running)
                        LabeledContent("Local pending updates", value: String(cloud.pendingCount))
                        if let previous = cloud.lastSuccessfulSync {
                            LabeledContent("Last successful sync") {
                                Text(
                                    Date(timeIntervalSince1970:
                                        TimeInterval(previous.finishedTimeMS) / 1_000),
                                    style: .relative
                                )
                            }
                            LabeledContent("Last uploaded / received", value:
                                "\(previous.uploaded) / \(previous.downloaded)")
                            if previous.moreComing || previous.pending > 0 {
                                Text("More changes pending")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Refresh local cache") { cloud.refresh() }
                        Button("Reset cloud change cursor") {
                            cloud.resetServerCursor()
                        }
                        .disabled(!cloud.cloudEnabled || cloud.running)
                    }
                    Section("Cloud clipboard data removal") {
                        Text("Local cache removal preserves offline clipboard history. Deleting the Nexus iCloud zone removes its cloud records, but another device can re-upload old copies unless sync is disabled there.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Clear local iCloud cache", role: .destructive) {
                            showLocalCloudClear = true
                        }
                        .disabled(cloud.running)
                        Button("Erase Nexus clipboard data from iCloud…",
                               role: .destructive) {
                            cloudEraseConfirmation = ""
                            showCloudEraseSheet = true
                        }
                        .disabled(cloud.running || !cloud.containerConfigured)
                    }
                    Section("Status") {
                        Text(cloud.status).foregroundStyle(.secondary)
                        Text("A signed build with the matching Apple CloudKit container and account is required for actual cross-device synchronization. The app cannot auto-paste into other iOS apps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Settings")
                .confirmationDialog(
                    "Clear only this device's iCloud clipboard cache?",
                    isPresented: $showLocalCloudClear,
                    titleVisibility: .visible
                ) {
                    Button("Clear local iCloud cache", role: .destructive) {
                        Task { await cloud.clearLocalCloudData() }
                    }
                } message: {
                    Text("Your offline clipboard history stays on this device. Cloud cache, queued changes and server cursor are cleared without network access.")
                }
                .sheet(isPresented: $showCloudEraseSheet) {
                    NavigationStack {
                        Form {
                            Section("Erase private Nexus iCloud clipboard zone") {
                                Text("This permanently deletes the NexusClipboard zone for the signed-in Apple account. Disable sync on other devices before erasing, or they may upload old content again. Offline clipboard history is preserved.")
                                    .font(.callout)
                                TextField("Type DELETE to confirm",
                                          text: $cloudEraseConfirmation)
                                    .autocorrectionDisabled()
                                Button("Erase Nexus iCloud records",
                                       role: .destructive) {
                                    let confirmation = cloudEraseConfirmation
                                    showCloudEraseSheet = false
                                    Task { await cloud.erasePrivateNexusCloudZone(confirmation: confirmation) }
                                }
                                .disabled(cloudEraseConfirmation != "DELETE" || cloud.running)
                            }
                        }
                        .navigationTitle("Erase iCloud Data")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showCloudEraseSheet = false }
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear {
            cloud.refresh()
            Task { await cloud.syncWhenForegroundEligible() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await cloud.syncWhenForegroundEligible() }
            }
        }
        .onChange(of: cloud.foregroundSyncEnabled) { enabled in
            if enabled && scenePhase == .active {
                Task { await cloud.syncWhenForegroundEligible() }
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: $fileExport,
            contentType: .data,
            defaultFilename: fileExportName
        ) { _ in
            fileExport = nil
        }
    }

    @ViewBuilder
    private func localHistoryCard(
        _ entry: MobileLocalClipboardEntry
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved on this device", systemImage: "iphone")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    cloud.deleteLocalText(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Text(entry.text)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Text(
                    Date(timeIntervalSince1970:
                        TimeInterval(entry.detectedTimeMS) / 1_000),
                    style: .date
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Copy text") {
                    cloud.copyLocalText(entry)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
    }

    @ViewBuilder
    private func historyCard(_ record: ClipboardCloudRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.tint)
                Text(record.revision.deviceID == "unknown"
                     ? String(localized: "Clipboard") : String(localized: "History"))
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    cloud.deleteLocalAndCloud(record)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if case .operation(let info)? = record.payload {
                if info.image != nil && cloud.includeImages {
                    MobileCloudImagePreview(cloud: cloud, recordID: record.id)
                }
                Text(
                    cloud.includeText
                        ? (info.text ?? String(localized: "Metadata only"))
                        : String(localized: "Content hidden by current privacy preference")
                )
                .font(.body)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Date(timeIntervalSince1970: TimeInterval(info.detectedTimeMS) / 1000),
                     style: .date)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy text") {
                        cloud.copyText(record)
                    }
                    .disabled(!cloud.includeText || info.text == nil)
                    if info.image != nil && cloud.includeImages {
                        Button("Copy image") {
                            cloud.copyRemoteImage(recordID: record.id)
                        }
                    }
                    if info.file != nil && cloud.includeFiles {
                        Button("Export file") {
                            guard let asset = cloud.cachedRemoteFile(
                                recordID: record.id
                            ) else { return }
                            fileExport = NexusCloudFileDocument(data: asset.bytes)
                            fileExportName = asset.reference.fileName
                            showFileExporter = true
                        }
                    }
                    if !collections.isEmpty {
                        Menu("Add to collection") {
                            ForEach(collections, id: \.id) { collection in
                                Button {
                                    cloud.addToCollection(operation: record,
                                                          collection: collection)
                                } label: {
                                    if case .collection(let info)? = collection.payload {
                                        Text(info.name)
                                    } else {
                                        Text("Collection")
                                    }
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(.secondary.opacity(0.2))
        }
    }
}

/// A bounded verified cloud file becomes a user-chosen Files export.
/// Never restores the sender's absolute path or writes without a picker.
private struct NexusCloudFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              data.count <= ClipboardCloudFileReference.maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Loads only the already-authorized local CloudKit cache, never the
/// system pasteboard. The CKAsset is validated before being committed.
private struct MobileCloudImagePreview: View {
    @ObservedObject var cloud: MobileClipboardController
    let recordID: String
    @State private var preview: UIImage?

    var body: some View {
        Group {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 180)
                    .accessibilityLabel("Cloud clipboard image")
            } else {
                Label("Image preview unavailable", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: recordID) {
            if let bytes = cloud.cachedRemoteImage(recordID: recordID) {
                preview = UIImage(data: bytes)
            } else {
                preview = nil
            }
        }
    }
}

@main
struct NexusClipboardMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileHomeView()
        }
    }
}
