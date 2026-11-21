import Foundation
import Testing
@testable import Nexus

@Suite("Welcome guide preference")
struct WelcomeGuideStoreTests {
    @Test("First launch shows the guide and a later launch does not")
    func shownOnlyOnceAutomatically() {
        let suite = "com.qssedalto.nexus.welcome-guide-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = WelcomeGuideStore(defaults: defaults)
        #expect(firstLaunch.shouldShowOnLaunch)
        firstLaunch.markShown()
        #expect(!firstLaunch.shouldShowOnLaunch)

        let nextLaunch = WelcomeGuideStore(defaults: defaults)
        #expect(!nextLaunch.shouldShowOnLaunch)
    }

    @Test("Other preferences do not suppress the welcome guide")
    func unrelatedPreferencesDoNotSuppressWelcome() {
        let suite = "com.qssedalto.nexus.welcome-guide-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "launchAtLoginEnabled")
        #expect(WelcomeGuideStore(defaults: defaults).shouldShowOnLaunch)
    }
}
