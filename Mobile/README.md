# Nexus Clipboard for iPhone and iPad

The separate universal iOS app is defined in project.ios.yml and is NOT
included in, or substituted for, the existing installed macOS Nexus bundle.
The app bundles native English and Simplified Chinese Localizable.strings
resources, declaring both languages in its own development Info.plist.

Source components:
- Sources/NexusClipboardMobile: SwiftUI iPhone/iPad tab layout, explicit
  clipboard import, local cache, permanent collections, privacy switches.
- Sources/NexusMobileCore: iOS-specific projection of the existing operation
  model and the shared CloudKit journal/codec/merge/transport source files.
- Mobile/NexusClipboardMobile-Info.plist: development-only iOS/iPadOS bundle.
- .github/workflows/nexus-mobile.yml: separate, unsigned iPhone/iPad Simulator build job.

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
- Separately consented macOS CloudKit uploads can include screenshot/image originals
  and eligible individual local regular-file originals, each limited to 8 MiB.
  The iPhone/iPad app can display/download authorized cloud images for explicit
  copy-again and export a cached cloud file on user request. This is not
  background file synchronization, recursive folder transfer, or general
  original-file acquisition from iOS/iPadOS apps. Large files, packages,
  symlinks and cloud-only provider placeholders are not transferred.
- The Mac and mobile clients require independently configured private CloudKit
  entitlement, container and permissions before any binary transfer can run.
  Merely building the unsigned simulators is not evidence of working transfer.
- The app stores an independent SQLite history of up to 500 explicitly
  imported text entries (64 KiB each) even when iCloud is disabled. Local
  delete and copy-again do not require an Apple Account. If iCloud is enabled,
  separately authorized imports may also be queued in the private journal.
- The app stores its own bounded local CloudKit cache; remote entries become
  visible on explicit sync or separately enabled throttled foreground sync.
  There is no background pasteboard polling or unattended iOS paste operation.
  A physically deleted CKRecord or a newer concurrent mutation may require
  explicit conflict handling.
- There is NO iOS release signing, distribution, on-device test, universal
  clipboard integration or claimed production cross-device acceptance yet.
- Existing macOS Nexus, Finder settings, Bundle IDs and user data are intact.


**Downloadable CI preview:** The [Nexus iPhone and iPad simulator build](https://github.com/qssedalto/Nexus/actions/workflows/nexus-mobile.yml) workflow exports an unsigned `NexusClipboardMobile.app` ZIP for the iOS Simulator. It is not signed or provisioned for physical iPhone/iPad installation. A physical-device build requires the owner's Apple development team, a compatible iOS provisioning profile, CloudKit container configuration, and verification on actual hardware.
