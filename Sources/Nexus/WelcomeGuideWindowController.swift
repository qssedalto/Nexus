import AppKit
import SwiftUI

extension Notification.Name {
    static let nexusShowWelcomeGuide = Notification.Name("com.qssedalto.nexus.showWelcomeGuide")
}

/// A real, centered window rather than a popover anchored to the menu bar:
/// it remains discoverable even when Hidden Bar or similar tools hide Nexus.
@MainActor
final class WelcomeGuideWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 490),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("Welcome to Nexus")
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: WelcomeGuideView(
                onContinue: { [weak self] in self?.dismiss() },
                onOpenSettings: { [weak self] in self?.onOpenSettings() }
            )
        )
        self.window = window

        // LSUIElement remains enabled. Temporarily expose this window in
        // the normal app switcher/Dock while onboarding is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct WelcomeGuideView: View {
    let onContinue: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(nsImage: AppIconProvider.image())
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 68, height: 68)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(localized("Welcome to Nexus"))
                                .font(.system(size: 26, weight: .bold))
                            Text(localized("Nexus is running."))
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(localized("Nexus lives in the menu bar, not the Dock. Here is how to find it."))
                        .font(.body)

                    Divider()

                    WelcomeGuideStep(
                        symbol: "menubar.rectangle",
                        title: localized("Find the Nexus menu bar icon"),
                        details: localized("Look in the upper-right menu bar. Click Nexus to open its menu, or drag a file onto the icon to copy its path.")
                    )
                    WelcomeGuideStep(
                        symbol: "eye",
                        title: localized("Using Hidden Bar or another menu bar organizer?"),
                        details: localized("Expand the hidden icons, find Nexus, and move or pin it into the visible menu bar area.")
                    )
                    WelcomeGuideStep(
                        symbol: "arrow.clockwise.circle",
                        title: localized("If you cannot find Nexus later"),
                        details: localized("Open Nexus again from Finder or Applications to show this guide. You can also reopen it from Settings → General.")
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(26)
            }

            Divider()

            HStack {
                Button(localized("Open Settings…"), action: onOpenSettings)
                Spacer()
                Button(localized("Got it — start using Nexus"), action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 490)
    }
}

private struct WelcomeGuideStep: View {
    let symbol: String
    let title: String
    let details: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(details)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
