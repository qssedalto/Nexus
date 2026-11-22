# Changelog

## 0.0.6

- Fix the Keyboard and Mouse Statistics tab overflow with a scrollable layout and separate date/time rows.
- Add a native macOS Services copy-path fallback in iCloud Drive and other File Provider locations where Finder Sync menus may not appear; macOS controls activation and placement.
- Link directly to macOS Services settings.
- Verify real signed CloudKit entitlements and require an authorized provisioning profile for opt-in CloudKit test builds.
- Leave ordinary Nexus builds CloudKit-disabled until configured with an authorized Apple developer container.

## 0.0.5

- Restore Finder **Copy Path** after updating from 0.0.4.
- Prevent stale Finder extension versions from adding duplicate **Copy Path** entries after future updates.
- Add **Copy Path** to Finder’s contextual menu, using the **Copy As** format selected in Nexus.
- Record Finder **Copy Path** actions in **Recently grabbed**, keeping copy history consistent with menu-bar drops.
- Add a dedicated Settings window for launch at login, Finder extension setup, updates, and app information.

## 0.0.4

- Add **Copy Path** to Finder’s contextual menu, using the **Copy As** format selected in Nexus.
- Record Finder **Copy Path** actions in **Recently grabbed**, keeping copy history consistent with menu-bar drops.
- Prevent duplicate **Copy Path** entries after updating Nexus while the Finder extension is enabled.
- Add a dedicated Settings window for launch at login, Finder extension setup, updates, and app information.

## 0.0.3

- Add **Copy Path** to Finder’s contextual menu, using the **Copy As** format selected in Nexus.
- Record Finder **Copy Path** actions in **Recently grabbed**, keeping copy history consistent with menu-bar drops.
- Add a dedicated Settings window for launch at login, Finder extension setup, updates, and app information.

## 0.0.2

- Add **Copy Path** to Finder’s contextual menu, using the **Copy As** format selected in Nexus.
- Add a dedicated Settings window for launch at login, Finder integration, updates, and app information.
- Improve Finder extension setup, development-build isolation, and signed release packaging.

## 0.0.1

- Initial development release with menu bar path drops, path formatting, recent history, launch-at-login control, and direct distribution scaffolding.
