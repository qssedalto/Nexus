import Foundation

/// A versioned per-installation preference: users see the guide only once
/// automatically, but can reopen it explicitly from Settings or Finder.
struct WelcomeGuideStore {
    static let shownKey = "nexus.welcomeGuide.shown.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldShowOnLaunch: Bool {
        !defaults.bool(forKey: Self.shownKey)
    }

    func markShown() {
        defaults.set(true, forKey: Self.shownKey)
    }
}
