import NexusCore
import SwiftUI

struct MenuPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var clipboardMonitor = ClipboardMonitor.shared
    @AppStorage("nexusPinnedClipboardOperationIDs") private var pinnedRaw = ""
    @State private var clipboardRecent: [RecordedOperation] = []
    @State private var clipboardPinned: [RecordedOperation] = []
    let buildInfo: AppBuildInfo
    let onPrepareSettings: () -> Void
    let onOpenLegacySettings: () -> Void
    let onOpenClipboardShelf: () -> Void
    let onOpenHelp: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker(localized("Copy As"), selection: Binding(
                get: { appState.selectedFormat },
                set: { appState.setSelectedFormat($0) }
            )) {
                ForEach(PathFormat.allCases) { format in
                    Text(localized(format.displayName)).tag(format)
                }
            }
            .pickerStyle(.menu)

            if let output = appState.lastCopiedOutput {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("Last copied"))
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    Button {
                        _ = appState.copyAgain(output)
                    } label: {
                        Text(output)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(MenuActionStyle())
                    .help(output)
                }
            }

            Divider()

            Button {
                onOpenClipboardShelf()
            } label: {
                HStack {
                    Label(localized("Open clipboard shelf"), systemImage: "square.stack.3d.up")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(MenuActionStyle())

            quickClipboardMenu
            recentPathsMenu
            if clipboardMonitor.paused {
                Text(localized("Clipboard history is paused. New copies are not added to sync."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                clipboardMonitor.paused.toggle()
            } label: {
                Label(
                    localized(clipboardMonitor.paused
                              ? "Resume clipboard history" : "Pause clipboard history"),
                    systemImage: clipboardMonitor.paused
                        ? "play.circle" : "pause.circle"
                )
            }
            .buttonStyle(MenuActionStyle())

            Divider()

            HStack {
                settingsButton
                Button(action: onOpenHelp) {
                    Label(localized("Help"), systemImage: "questionmark.circle")
                }
                Spacer()

                Button(role: .destructive) {
                    onQuit()
                } label: {
                    Label(localized("Quit"), systemImage: "power")
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .font(.custom("Avenir Next", size: 13))
        .labelStyle(MenuAlignedLabelStyle())
        .foregroundStyle(.primary)
        .task(id: pinnedRaw + "-" + String(clipboardMonitor.savedRevision)) {
            await loadQuickClipboard()
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            OpenSettingsButton(onBeforeOpen: onPrepareSettings)
        } else {
            Button(action: onOpenLegacySettings) {
                Label(localized("Settings…"), systemImage: "gearshape")
            }
        }
    }

    private var quickClipboardMenu: some View {
        Menu {
            if clipboardRecent.isEmpty && clipboardPinned.isEmpty {
                Text(localized("No recorded clipboard entries"))
            } else {
                if !clipboardPinned.isEmpty {
                    Section(localized("Pinned clipboard")) {
                        ForEach(clipboardPinned, id: \.id) { item in
                            Button {
                                restoreClipboard(item)
                            } label: {
                                Label(
                                    ClipboardQuickMenuSummary.title(for: item),
                                    systemImage: "pin.fill"
                                )
                            }
                        }
                    }
                }
                Section(localized("Recent clipboard")) {
                    ForEach(clipboardRecent, id: \.id) { item in
                        Button {
                            restoreClipboard(item)
                        } label: {
                            Label(
                                ClipboardQuickMenuSummary.title(for: item),
                                systemImage: item.type == "image_copy" ? "photo" : "doc"
                            )
                        }
                    }
                }
            }
            Divider()
            Button {
                onOpenClipboardShelf()
            } label: {
                Label(localized("Open clipboard shelf"), systemImage: "square.stack.3d.up")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").frame(width: 20)
                Text(localized("Recent clipboard"))
                Spacer()
                Text("\(clipboardRecent.count)")
                    .font(.caption.monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private func loadQuickClipboard() async {
        let store = OperationStore.shared()
        let pins = Set(pinnedRaw.split(separator: "\n").map(String.init))
        let values = await Task.detached(priority: .utility) {
            let rows = (try? store?.query(
                from: 0, to: Int64.max, limit: 30
            )) ?? []
            let favourites = (try? store?.query(ids: Array(pins))) ?? []
            let pinned = ClipboardQuickMenuSummary.recent(
                from: favourites.filter { pins.contains($0.id) }, limit: 3
            )
            return (
                ClipboardQuickMenuSummary.recent(from: rows, limit: 5),
                pinned
            )
        }.value
        guard !Task.isCancelled else { return }
        clipboardRecent = values.0
        clipboardPinned = values.1
    }

    private func restoreClipboard(_ item: RecordedOperation) {
        if let error = ClipboardRecordRestorer.restore(item) {
            appState.clipboardCopyDidFail(error)
        } else {
            appState.clipboardCopyDidSucceed()
        }
    }

    private var recentPathsMenu: some View {
        Menu {
            if appState.history.entries.isEmpty {
                Text(localized("No copied paths yet"))
            } else {
                ForEach(appState.history.entries, id: \.self) { output in
                    Button {
                        _ = appState.copyAgain(output)
                    } label: {
                        Text(output).lineLimit(1)
                    }
                    .help(output)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").frame(width: 20)
                Text(localized("Recently grabbed"))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconProvider.image())
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(buildInfo.isDriveEdition ? "Nexus Drive" : "Nexus")
                        .font(.custom("Avenir Next", size: 16).weight(.bold))

                    if buildInfo.showsDevelopmentLabel {
                        Text(localized("DEV"))
                            .font(.custom("Avenir Next", size: 9).weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(buildInfo.showsDevelopmentLabel
                     ? localized("Development build")
                     : localized("Drop files. Grab paths."))
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let feedback = appState.feedback {
                Label(feedback.message, systemImage: feedback.symbol)
                    .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    .foregroundStyle(feedback.color)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.snappy(duration: 0.18), value: appState.feedback)
    }
}

private struct MenuAlignedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 20, alignment: .center)
            configuration.title
        }
    }
}

private struct MenuActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

@available(macOS 14.0, *)
private struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    let onBeforeOpen: () -> Void

    var body: some View {
        Button {
            onBeforeOpen()
            openSettings()
        } label: {
            Label(localized("Settings…"), systemImage: "gearshape")
        }
    }
}
