import AppKit
import FinderSync
import NexusCore
import UniformTypeIdentifiers

final class FinderSync: FIFinderSync {
    private let settings = SharedSettings.makeStore()
    private let pathFormatReader = SharedSettings.makePathFormatReader()
    private let versionStore = SharedSettings.makeFinderExtensionVersionStore()
    private let version = SharedSettings.finderExtensionVersion()

    override init() {
        super.init()

        updateMonitoredVolumes()
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspaceNotifications.addObserver(self, selector: #selector(mountedVolumesChanged), name: notification, object: nil)
        }
    }

    @objc
    private func mountedVolumesChanged(_ notification: Notification) {
        updateMonitoredVolumes()
    }

    private func updateMonitoredVolumes() {
        // Finder routes requests by volume. A registration for "/" only covers its own volume.
        var roots = Set(FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? [])
        roots.insert(URL(fileURLWithPath: "/", isDirectory: true))
        FIFinderSyncController.default().directoryURLs = roots
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        #if NEXUS_SERVICE_PROTOTYPE
        return nil
        #else
        guard menuKind == .contextualMenuForItems,
              version.map({ versionStore?.isActive(version: $0) ?? true }) ?? true else {
            return nil
        }

        let urls = selectedURLs()
        guard !urls.isEmpty else { return nil }

        let menu = NSMenu(title: "Nexus")
        let copyItem = NSMenuItem(
            title: Self.copyTitle(for: urls),
            action: #selector(copySelectedPaths),
            keyEquivalent: ""
        )
        copyItem.target = self
        if settings?.useFinderSubmenu == true {
            let group = NSMenuItem(title: "Nexus", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Nexus")
            submenu.addItem(copyItem)
            group.submenu = submenu
            menu.addItem(group)
        } else {
            menu.addItem(copyItem)
        }
        return menu
        #endif
    }

    private func selectedURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selection = controller.selectedItemURLs(), !selection.isEmpty {
            return selection
        }
        return controller.targetedURL().map { [$0] } ?? []
    }

    private static func copyTitle(for urls: [URL]) -> String {
        let kinds = Set(urls.map(itemKind))
        switch (kinds.count == 1 ? kinds.first : nil, urls.count == 1) {
        case (.folder, true):
            return String(localized: "Copy Folder Path")
        case (.folder, false):
            return String(localized: "Copy Folder Paths")
        case let (.file(type?), single):
            let format = single
                ? String(localized: "Copy %@ Path")
                : String(localized: "Copy %@ Paths")
            return String.localizedStringWithFormat(format, type)
        case (.file, true):
            return String(localized: "Copy File Path")
        case (.file, false):
            return String(localized: "Copy File Paths")
        default:
            return String(localized: "Copy Selected Paths")
        }
    }

    private enum ItemKind: Hashable {
        case folder
        case file(String?)
    }

    private static func itemKind(for url: URL) -> ItemKind {
        let metadata = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        if (metadata?.isDirectory ?? url.hasDirectoryPath), metadata?.isPackage != true {
            return .folder
        }

        let candidates = [metadata?.contentType, UTType(filenameExtension: url.pathExtension)]
        let type = candidates.compactMap { $0 }.first {
            $0.isDeclared && $0 != .item && $0 != .content && $0 != .data
        }
        return .file(type?.localizedDescription)
    }

    @objc
    private func copySelectedPaths() {
        let format = pathFormatReader?.selectedFormat ?? .shellEscaped
        let copyAction = PathCopyAction(clipboardWriter: FinderClipboardWriter(), historyStore: settings, operationStore: OperationStore.shared())
        if (try? copyAction.copy(urls: selectedURLs(), as: format)) != nil {
            DistributedNotificationCenter.default().post(name: SharedSettings.finderCopyNotification, object: nil)
        }
    }
}

private struct FinderClipboardWriter: ClipboardWriting {
    func writeString(_ string: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(string, forType: .string) else {
            throw FinderClipboardError.writeFailed
        }
    }
}

private enum FinderClipboardError: Error {
    case writeFailed
}
