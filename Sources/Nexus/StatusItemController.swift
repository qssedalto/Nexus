import AppKit
import ApplicationServices
import Combine
import SwiftUI
import NexusCore

@MainActor
final class StatusItemController {
    private let appState: AppState
    private let buildInfo = AppBuildInfo.current()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let feedbackPopover = NSPopover()
    private var centeredMenu: NSPanel?
    private var unanchoredFeedbackWindow: NSPanel?
    private let dropReadyPopover = NSPopover()
    private var clipboardShelfPanel: NSPanel?
    private var previousFrontmostApp: NSRunningApplication?
    private var statusView: DropTargetStatusView?
    private var dropReadyShowTask: DispatchWorkItem?
    private var feedbackDismissTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
    }

    func install() {
        guard let button = statusItem.button else {
            return
        }

        statusItem.length = buildInfo.showsDevelopmentLabel ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.image = StatusIconProvider.image(for: .idle)
        button.image?.size = NSSize(width: 22, height: 22)
        button.title = buildInfo.showsDevelopmentLabel ? localized(" DEV") : ""
        button.toolTip = buildInfo.isDriveEdition
            ? "Nexus Drive"
            : (buildInfo.showsDevelopmentLabel ? localized("Nexus Dev Build") : "Nexus")
        button.imagePosition = buildInfo.showsDevelopmentLabel ? .imageLeft : .imageOnly
        button.contentTintColor = nil

        let view = DropTargetStatusView(frame: button.bounds)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.statusButton = button
        view.onClick = { [weak self] in
            self?.togglePopover()
        }
        view.onDragSessionStarted = { [weak self] in
            self?.prepareForStatusItemDrop()
        }
        view.onDropTargetArmed = { [weak self] in
            self?.showDropReadyCue()
        }
        view.onDropTargetDisarmed = { [weak self] in
            self?.hideDropReadyCue()
        }
        view.onDrop = { [weak appState] urls in
            return appState?.handleDroppedURLs(urls) ?? false
        }
        view.onRejectedDrop = { [weak appState] in
            appState?.handleDroppedURLs([])
        }
        button.addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        statusView = view
        ClipboardHotkeyController.shared.onToggle = { [weak self] in
            self?.toggleClipboardShelf()
        }
        ClipboardHotkeyController.shared.install()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: menuPopoverHeight)
        popover.contentViewController = menuContent()

        feedbackPopover.behavior = .transient
        feedbackPopover.contentSize = FeedbackPopoverView.contentSize
        dropReadyPopover.behavior = .transient
        dropReadyPopover.contentSize = NSSize(width: 280, height: 66)

        appState.$feedback
            .compactMap { $0 }
            .sink { [weak self] feedback in
                self?.showFeedbackPopover(feedback)
            }
            .store(in: &cancellables)
    }

    private func prepareForStatusItemDrop() {
        keepStatusViewOnTop()
        feedbackDismissTask?.cancel()
        hideDropReadyCue()
        dismissFeedbackPopover()
        closeMenu()
    }

    private func togglePopover() {
        if popover.isShown || centeredMenu?.isVisible == true {
            closeMenu()
        } else {
            showMenu()
        }
    }

    func showMenu() {
        if popover.isShown { return }
        if let centeredMenu, centeredMenu.isVisible {
            centeredMenu.makeKeyAndOrderFront(nil)
            return
        }
        dismissFeedbackPopover()
        appState.refreshHistory()
        appState.refreshFinderExtensionStatus()
        guard let anchor = visibleMenuAnchor else {
            showCenteredMenu()
            return
        }
        keepStatusViewOnTop()
        popover.contentSize = NSSize(width: 360, height: menuPopoverHeight)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        guard popover.isShown else {
            showCenteredMenu()
            return
        }
        clearMenuPopoverFocus()
        DispatchQueue.main.async { [weak self] in self?.clearMenuPopoverFocus() }
    }

    private var visibleMenuAnchor: NSStatusBarButton? {
        guard statusItem.isVisible, let button = statusItem.button, !button.isHiddenOrHasHiddenAncestor,
              button.alphaValue > 0, let window = button.window, window.alphaValue > 0,
              window.isVisible, window.occlusionState.contains(.visible)
        else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard !frame.isEmpty, NSScreen.screens.contains(where: {
            $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
        }) else { return nil }
        return button
    }

    private func showCenteredMenu() {
        let panel = centeredMenu ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: menuPopoverHeight),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = localized("Nexus menu")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = menuContent()
        panel.setContentSize(NSSize(width: 360, height: menuPopoverHeight))
        if let visible = interactionScreen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        centeredMenu = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func menuContent() -> NSHostingController<MenuPopoverView> {
        NSHostingController(rootView: MenuPopoverView(
            appState: appState, buildInfo: buildInfo,
            onPrepareSettings: { [weak self] in self?.prepareToOpenSettings() },
            onOpenLegacySettings: { [weak self] in self?.openLegacySettings() },
            onOpenClipboardShelf: { [weak self] in self?.showClipboardShelf() },
            onOpenHelp: { [weak self] in
                self?.closeMenu()
                NotificationCenter.default.post(name: .nexusShowWelcomeGuide, object: nil)
            },
            onQuit: { NSApp.terminate(nil) }
        ))
    }

    private func closeMenu() {
        popover.performClose(nil)
        centeredMenu?.orderOut(nil)
    }

    private var interactionScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func clearMenuPopoverFocus() {
        guard let window = popover.contentViewController?.view.window else {
            return
        }

        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
    }

    private var menuPopoverHeight: CGFloat {
        appState.lastCopiedOutput == nil ? 380 : 442
    }

    private func toggleClipboardShelf() {
        if clipboardShelfPanel?.isVisible == true {
            clipboardShelfPanel?.orderOut(nil)
        } else {
            showClipboardShelf()
        }
    }

    private func showClipboardShelf() {
        closeMenu()
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }

        let panel: NSPanel
        if let existing = clipboardShelfPanel {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            created.title = localized("Clipboard Shelf")
            // A normal window can be covered by other apps. Do not permanently float above them.
            created.level = .normal
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.moveToActiveSpace]
            created.minSize = NSSize(width: 820, height: 580)
            created.setFrameAutosaveName("NexusClipboardShelf")
            created.contentViewController = NSHostingController(
                rootView: ClipboardShelfView(
                    appState: appState,
                    onPasteRequested: { [weak self] in self?.pasteIntoPreviousApp() },
                    onCloseRequested: { [weak self] in self?.clipboardShelfPanel?.orderOut(nil) }
                )
            )
            clipboardShelfPanel = created
            panel = created
        }

        let mouseLocation = NSEvent.mouseLocation
        let preferredScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
        if let visible = preferredScreen?.visibleFrame,
           !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) {
            let frame = ClipboardPanelPlacement.frame(
                inside: visible, requestedSize: panel.frame.size,
                bottomInset: 24
            )
            panel.setFrame(frame, display: true)
        }
        appState.refreshOperations()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Raise once on explicit user invocation, without always-on-top behavior.
        panel.orderFrontRegardless()
    }

    /// Called only following an explicit double click or Return by the user.
    /// The clipboard is already populated. When focus or permissions cannot
    /// be verified we leave it copied rather than injecting into a wrong app.
    private func pasteIntoPreviousApp() {
        guard let target = previousFrontmostApp,
              target.bundleIdentifier != Bundle.main.bundleIdentifier,
              target.isTerminated == false else {
            return
        }
        guard AXIsProcessTrusted() else {
            // Stable documented AX option key. Reading the imported CF
            // global constant directly violates Swift 6 strict concurrency.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        // The selected card was just copied into NSPasteboard. If the user
        // copies something else before target activation finishes, abort
        // instead of pasting the intervening clipboard contents.
        let expectedChangeCount = NSPasteboard.general.changeCount
        clipboardShelfPanel?.orderOut(nil)
        guard target.activate(options: [.activateIgnoringOtherApps]) else { return }
        let expectedPID = target.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
            guard ClipboardPasteSafety.canRequestPaste(
                hasAccessibilityPermission: AXIsProcessTrusted(),
                expectedTargetPID: expectedPID,
                currentFrontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                expectedClipboardChangeCount: expectedChangeCount,
                currentClipboardChangeCount: NSPasteboard.general.changeCount
            ) else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if !InputStatisticsController.shared.monitoringActive ||
                !UserDefaults.standard.bool(forKey: "nexusMonitorPasteRequests") {
                self.appState.clipboardDidChange("Paste detected")
            }
        }
    }

    private func prepareToOpenSettings() {
        closeMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openLegacySettings() {
        prepareToOpenSettings()
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !opened {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func showFeedbackPopover(_ feedback: DropFeedback) {
        let duration = appState.feedbackDuration
        feedbackDismissTask?.cancel()
        dismissFeedbackPopover()
        hideDropReadyCue()
        // Both menu presentations already display feedback in their header.
        guard duration > 0, !popover.isShown, centeredMenu?.isVisible != true else { return }

        if let anchor = visibleMenuAnchor {
            let content = NSHostingController(rootView: FeedbackPopoverView(feedback: feedback))
            feedbackPopover.contentViewController = content
            feedbackPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            if feedbackPopover.isShown {
                content.view.window?.ignoresMouseEvents = true
            } else {
                feedbackPopover.contentViewController = nil
                showUnanchoredFeedback(feedback)
            }
        } else {
            showUnanchoredFeedback(feedback)
        }
        feedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { self?.dismissFeedbackPopover() }
        }
    }

    private func dismissFeedbackPopover() {
        feedbackPopover.performClose(nil)
        unanchoredFeedbackWindow?.orderOut(nil)
    }

    private func showUnanchoredFeedback(_ feedback: DropFeedback) {
        let panel: NSPanel
        if let existing = unanchoredFeedbackWindow {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: FeedbackPopoverView.contentSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            unanchoredFeedbackWindow = panel
        }
        panel.contentViewController = NSHostingController(
            rootView: FeedbackPopoverView(feedback: feedback)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        if let visible = interactionScreen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: max(visible.minX, visible.maxX - panel.frame.width - 12),
                y: max(visible.minY, visible.maxY - panel.frame.height - 8)
            ))
        }
        panel.orderFrontRegardless()
    }

    private func showDropReadyCue() {
        guard let anchorView = statusItem.button,
              !popover.isShown,
              !dropReadyPopover.isShown else {
            return
        }

        dropReadyShowTask?.cancel()
        let task = DispatchWorkItem { [weak self, weak anchorView] in
            guard let self,
                  let anchorView,
                  !self.dropReadyPopover.isShown,
                  !self.popover.isShown else {
                return
            }

            self.showDropReadyPopover(relativeTo: anchorView)
        }
        dropReadyShowTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
    }

    private func hideDropReadyCue() {
        dropReadyShowTask?.cancel()
        dropReadyShowTask = nil
        dropReadyPopover.performClose(nil)
    }

    private func showDropReadyPopover(relativeTo anchorView: NSView) {
        dropReadyPopover.contentViewController = NSHostingController(rootView: DropReadyPopoverView())
        dropReadyPopover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        dropReadyPopover.contentViewController?.view.window?.ignoresMouseEvents = true
    }

    private func keepStatusViewOnTop() {
        guard let statusView,
              let button = statusItem.button,
              statusView.superview === button else {
            return
        }

        statusView.layer?.zPosition = CGFloat.greatestFiniteMagnitude
    }
}
