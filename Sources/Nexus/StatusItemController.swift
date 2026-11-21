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

        statusItem.length = buildInfo.isDevBuild ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.image = StatusIconProvider.image(for: .idle)
        button.image?.size = NSSize(width: 22, height: 22)
        button.title = buildInfo.isDevBuild ? localized(" DEV") : ""
        button.toolTip = buildInfo.isDevBuild ? localized("Nexus Dev Build") : "Nexus"
        button.imagePosition = buildInfo.isDevBuild ? .imageLeft : .imageOnly
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
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverView(
                appState: appState,
                buildInfo: buildInfo,
                onPrepareSettings: { [weak self] in
                    self?.prepareToOpenSettings()
                },
                onOpenLegacySettings: { [weak self] in
                    self?.openLegacySettings()
                },
                onOpenClipboardShelf: { [weak self] in
                    self?.showClipboardShelf()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        feedbackPopover.behavior = .transient
        feedbackPopover.contentSize = NSSize(width: 280, height: 66)

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
        feedbackPopover.performClose(nil)
        popover.performClose(nil)
    }

    private func togglePopover() {
        guard let anchorView = statusItem.button else {
            return
        }
        keepStatusViewOnTop()

        if popover.isShown {
            popover.performClose(nil)
        } else {
            appState.refreshHistory()
            appState.refreshFinderExtensionStatus()
            popover.contentSize = NSSize(width: 360, height: menuPopoverHeight)
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            clearMenuPopoverFocus()
            DispatchQueue.main.async { [weak self] in
                self?.clearMenuPopoverFocus()
            }
            keepStatusViewOnTop()
        }
    }

    private func clearMenuPopoverFocus() {
        guard let window = popover.contentViewController?.view.window else {
            return
        }

        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
    }

    private var menuPopoverHeight: CGFloat {
        appState.lastCopiedOutput == nil ? 355 : 417
    }

    private func toggleClipboardShelf() {
        if clipboardShelfPanel?.isVisible == true {
            clipboardShelfPanel?.orderOut(nil)
        } else {
            showClipboardShelf()
        }
    }

    private func showClipboardShelf() {
        popover.performClose(nil)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }

        let panel: NSPanel
        if let existing = clipboardShelfPanel {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            created.title = localized("Clipboard Shelf")
            created.level = .floating
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        if let visible = preferredScreen?.visibleFrame {
            let frame = ClipboardPanelPlacement.frame(
                inside: visible, requestedSize: panel.frame.size
            )
            panel.setFrame(frame, display: true)
        }
        appState.refreshOperations()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func prepareToOpenSettings() {
        popover.performClose(nil)
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
        guard let anchorView = statusItem.button else {
            return
        }

        feedbackDismissTask?.cancel()
        hideDropReadyCue()
        if feedbackPopover.isShown {
            feedbackPopover.performClose(nil)
        }

        if popover.isShown {
            feedbackPopover.performClose(nil)
        } else {
            feedbackPopover.contentViewController = NSHostingController(
                rootView: FeedbackPopoverView(feedback: feedback)
            )
            feedbackPopover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            feedbackPopover.contentViewController?.view.window?.ignoresMouseEvents = true
        }

        feedbackDismissTask = Task { [weak feedbackPopover] in
            try? await Task.sleep(for: .seconds(appState.feedbackDuration))
            await MainActor.run {
                if !Task.isCancelled {
                    feedbackPopover?.performClose(nil)
                }
            }
        }
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
