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
                        .foregroundStyle(.secondary)
                    RecentPathRow(output: output) {
                        appState.copyAgain(output)
                    }
                }
            }

            Divider()

            Button {
                onOpenClipboardShelf()
            } label: {
                HStack {
                    Label(localized("Clipboard Shelf"), systemImage: "square.stack.3d.up")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)

            quickClipboardMenu
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
            .buttonStyle(.borderless)
            historyMenu

            Divider()

            HStack {
                settingsButton
                Button {
                    NotificationCenter.default.post(name: .nexusShowWelcomeGuide, object: nil)
                } label: {
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
                                onOpenClipboardShelf()
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
                            onOpenClipboardShelf()
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
                Label(localized("Quick clipboard history"), systemImage: "doc.on.clipboard")
                Spacer()
                Text("\(clipboardRecent.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
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

    private var historyMenu: some View {
        Menu {
            if appState.history.entries.isEmpty {
                Text(localized("No copied paths yet"))
            } else {
                Section(localized("Copy again")) {
                    ForEach(appState.history.entries, id: \.self) { output in
                        Button {
                            appState.copyAgain(output)
                        } label: {
                            Label(historyMenuTitle(for: output), systemImage: "doc.on.doc")
                        }
                        .help(output)
                    }
                }

                Divider()

                Button(role: .destructive) {
                    appState.clearHistory()
                } label: {
                    Label(localized("Clear History"), systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Label(localized("Recently grabbed"), systemImage: "clock.arrow.circlepath")
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                Spacer()
                Text(historyCountTitle)
                    .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var historyCountTitle: String {
        let count = appState.history.entries.count
        return count == 1 ? localized("1 item") : String.localizedStringWithFormat(localized("%lld items"), Int64(count))
    }

    private func historyMenuTitle(for output: String) -> String {
        let normalized = output
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > 30 else {
            return normalized
        }

        let head = normalized.prefix(13)
        let tail = normalized.suffix(14)
        return "\(head)...\(tail)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconProvider.image())
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Nexus")
                        .font(.custom("Avenir Next", size: 16).weight(.bold))

                    if buildInfo.isDevBuild {
                        Text(localized("DEV"))
                            .font(.custom("Avenir Next", size: 9).weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(buildInfo.isDevBuild ? localized("Development build") : localized("Drop files. Grab paths."))
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let feedback = appState.feedback {
                Label(feedback.message, systemImage: feedback.kind == .success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    .foregroundStyle(feedback.kind == .success ? .green : .red)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.snappy(duration: 0.18), value: appState.feedback)
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
