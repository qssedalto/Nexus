# Nexus Clipboard for iPhone and iPad

The separate universal iOS app is defined in project.ios.yml and is NOT
included in, or substituted for, the existing installed macOS Nexus bundle.

Source components:
- Sources/NexusClipboardMobile: SwiftUI iPhone/iPad tab layout, explicit
  clipboard import, local cache, permanent collections, privacy switches.
- Sources/NexusMobileCore: iOS-specific projection of the existing operation
  model and the shared CloudKit journal/codec/merge/transport source files.
- Mobile/NexusClipboardMobile-Info.plist: development-only iOS/iPadOS bundle.
- .github/workflows/nexus-macos.yml: separate, unsigned simulator build job.

Build and verification (macOS Xcode required):
1. Run xcodegen generate --spec project.ios.yml.
2. Run xcodebuild -project NexusClipboardMobile.xcodeproj -scheme
   NexusClipboardMobile -configuration Debug -destination
   'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build.
3. For on-device CloudKit, create an actual iOS App ID with an Apple
   Developer team and CloudKit entitlement matching the Mac's private
   container. Add the real NexusCloudKitContainerIdentifier to the
   **separately signed** test build; it is not supplied here.
4. Test iPhone and iPad separately for clipboard privacy prompts, multiwindow,
   orientation, local storage persistence, network loss, Apple Account
   sign-in/out, deletion tombstones, conflicts, and text copy-again.

Deliberate platform limitations:
- Apple restricts cross-app pasteboard observation in iOS/iPadOS. The app only
  reads a clipboard entry after the user taps Import clipboard while in front.
  It does NOT auto-monitor, collect keystrokes or auto-paste into other apps.
- Original images and files are not transferred. The CloudKit metadata model
  is shared with macOS but binary asset synchronization is not implemented.
- The app stores its own bounded local CloudKit cache; remote entries become
  visible when the user explicitly syncs. A physically deleted CKRecord or a
  newer concurrent mutation may require explicit conflict handling.
- There is NO iOS release signing, distribution, on-device test, universal
  clipboard integration or claimed production cross-device acceptance yet.
- Existing macOS Nexus, Finder settings, Bundle IDs and user data are intact.
