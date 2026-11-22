import AppKit
import SwiftUI

struct AboutView: View {
    let buildInfo: AppBuildInfo
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void

    private struct AboutLink: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let url: URL
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                aboutContent
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    private var aboutContent: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: AppIconProvider.image())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(appName)
                            .font(.custom("Avenir Next", size: 26, relativeTo: .title).weight(.bold))

                        if buildInfo.showsDevelopmentLabel {
                            Text(localized("DEV"))
                                .font(.custom("Avenir Next", size: 9, relativeTo: .caption2).weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.orange, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }

                    Text(versionLine)
                        .foregroundStyle(.secondary)
                }
            }

            Text(localized("Your Mac. Your Control."))
                .font(.headline)

            Text(localized("Drop files on the menu bar and copy clean filesystem paths instantly."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 20) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: link.systemImage)
                    }
                }
                Button {
                    openNexusWebsite()
                } label: {
                    Label(localized("Website"), systemImage: "globe")
                }
                .buttonStyle(.link)
            }

            Button(localized("Check for Updates"), action: onCheckForUpdates)
                .disabled(!canCheckForUpdates)

            if let copyright {
                Text(copyright)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var links: [AboutLink] {
        [
            makeLink(
                id: "github",
                title: "GitHub",
                systemImage: "chevron.left.forwardslash.chevron.right",
                rawURL: "https://github.com/qssedalto/Nexus"
            ),
        ].compactMap { $0 }
    }

    /// Open the self-contained public-facing Nexus product page bundled
    /// with the app. A file URL needs no GitHub account, no server and no
    /// login. Do not redirect to the generic qsseda.com homepage.
    private func openNexusWebsite() {
        let page = Bundle.main.url(forResource: "NexusWebsite", withExtension: "html")
            ?? Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources/NexusWebsite.html"
            )
        guard FileManager.default.fileExists(atPath: page.path) else {
            let alert = NSAlert()
            alert.messageText = localized("Nexus website is unavailable")
            alert.informativeText = localized("The product page is missing from this build. Rebuild Nexus Drive to restore it.")
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(page)
    }

    private func makeLink(id: String, title: String, systemImage: String, rawURL: String) -> AboutLink? {
        guard let url = URL(string: rawURL), !rawURL.isEmpty else {
            return nil
        }

        return AboutLink(id: id, title: title, systemImage: systemImage, url: url)
    }

    private var appName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        return "Nexus"
    }

    private var versionLine: String {
        String.localizedStringWithFormat(localized("Version %@ (%@)"), shortVersion, buildNumber)
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var copyright: String? {
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String).map { localized($0) }
    }
}
