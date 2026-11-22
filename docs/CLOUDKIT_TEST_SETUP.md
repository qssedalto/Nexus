# Opt-in private CloudKit configuration (NOT enabled in default Nexus builds)

The default Nexus app, Finder extension, Release, Debug, ServicesOnly and CI
builds **do not have CloudKit entitlements** and cannot upload the clipboard.
This is why Settings shows “CloudKit container not configured for this build”.
Simply turning on the iCloud clipboard toggle cannot add an Apple entitlement.
Do not replace a working installation implicitly.

For a separately provisioned **local macOS test build**, `Scripts/package_app.sh`
now supports two explicit, nonsecret local settings:
- `NEXUS_CLOUDKIT_CONTAINER_ID`: the actual CloudKit container granted to this App ID.
- `NEXUS_CLOUDKIT_PROVISIONING_PROFILE`: the absolute path to a matching macOS
  development provisioning profile exported from your own Apple Developer account.

Set these for a **development-signed, separate `Nexus Dev.app`** build, alongside the
existing `SIGNING_MODE=development` and `APP_IDENTITY` settings. Example:
```zsh
NEXUS_CLOUDKIT_CONTAINER_ID='iCloud.YOUR_REGISTERED_CONTAINER' NEXUS_CLOUDKIT_PROVISIONING_PROFILE='/path/to/YOUR.provisionprofile' SIGNING_MODE=development APP_IDENTITY='YOUR_APPLE_DEVELOPMENT_IDENTITY' ./Scripts/package_app.sh release --dev
```
Replace the placeholders with real developer resources; the example does
not create an iCloud container or issue an entitlement. The package script
keeps the default CloudKit-disabled builds unchanged, validates the presence
of the profile and ID, embeds the profile and signs the app with a matching
CloudKit entitlement. A profile not authorized for the bundle ID/container may
still fail on-device: confirm the actual signing entitlements and provisioning
in Xcode before using the app.

The Swift code includes opt-in privacy/settings panels on macOS and a universal
iPhone/iPad client, with a private CKRecordZone named NexusClipboard. To exercise it on a Mac with
a real Apple Developer team and a signed test build:

1. In the Apple Developer portal create or select an appropriate iCloud
   CloudKit container belonging to the signing team. Use that container's
   **actual** identifier; never use a guessed iCloud identifier.
2. Create a **separate development signing configuration** (not the existing
   installed Release bundle). Enable the iCloud / CloudKit capability for the
   application in Xcode. Its signed entitlements must include
   com.apple.developer.icloud-services = CloudKit and
   com.apple.developer.icloud-container-identifiers = [actual identifier].
   Preserve the existing application-group entitlement, so local history
   remains accessible in the test build.
3. Pass the real container ID as the Xcode build setting
   NEXUS_CLOUDKIT_CONTAINER_ID. project.yml reads this as the app's
   NexusCloudKitContainerIdentifier Info.plist key. If omitted or left as
   the Xcode placeholder, the controller blocks all CloudKit calls.
4. Sign/run the isolated build using a compatible provisioning profile.
   Sign into the desired Apple Account. In Nexus Settings > iCloud Clipboard,
   explicitly enable the category-level consent switches.
5. Click **Prepare next local history page** (200 items per request, bounded),
   **Create private iCloud zone**, then **Sync now**. To download more server
   change pages, click Sync again. Automatic periodic sync is separately
   opt-in on macOS and requires both authorization and a configured container;
   it does not turn on merely by opening Settings.
6. On a second Mac signed for the *same* container and Apple Account, repeat
   setup and fetch. Check deletion tombstones, conflict recovery, duplicate
   retries, sign-out, permission revocation, network loss, file-only records,
   Unicode filenames and the Finder extension independently.

Privacy and scope:

- CloudKit stores operation **metadata only by default**. Copied text,
  file/collection names and local file paths require independent opt-ins.
- Separately authorized original clipboard images and eligible single local
  regular-file payloads (up to **8 MiB each**) can be stored as private
  CloudKit CKAssets. Image and file permissions are independent; the default
  remains off. Large files, packages, symlinks, recursive directories and
  cloud-only File Provider placeholders are excluded from direct transfer.
  Signed live binary round-trip fidelity and quota/error handling have not
  been verified. Remote file *paths* are descriptive metadata, not valid
  file references on other devices; iPhone/iPad can explicitly export a
  previously downloaded file or copy an authorized image.
- Current transport expects logical deletion tombstones rather than physically
  deleting a record from the CloudKit zone. It does **not** reconcile every
  retention-cleanup deletion automatically, and does not provide a verified
  server-side purge operation. Do not market it as fully synchronized deletion.
- Disabling permission prevents further sync, but previously uploaded data
  remains in the Apple private database until separately deleted.
- macOS CI exercises the codec, deterministic merge, offline journal,
  mock transport and unsigned build. It **cannot** verify real Apple account
  access, CloudKit server permissions or end-to-end device synchronization.
- A separate universal iPhone/iPad SwiftUI app compiles for unsigned iOS
  Simulator in CI; it does not have a signed device build or distribution
  pipeline. It never automatically installs any app on another device and
  cannot silently observe the iOS clipboard in the background.


## Explicit cloud data removal (manual)

The macOS and iOS/iPadOS Settings screens now present TWO different, destructive
actions. Neither runs on app launch, disable-sync, sign-out or automatic history
retention.

- **Clear local iCloud cache**: clears only the current device's CloudKit
  journal, queued changes, cursors and (on Mac) imported cloud history/collection
  mirrors. Independently saved clipboard history and user-created collections
  remain intact. This does not delete records from Apple iCloud.
- **Erase Nexus clipboard data from iCloud**: requires a separate confirmation
  sheet and the literal text `DELETE`. Before connecting to Apple, the app
  persistently disables synchronization on this device. The dedicated private
  `NexusClipboard` CKRecordZone is deleted. If remote deletion succeeds, its
  local cloud journal/cursors and mirrors are discarded. If network deletion
  fails, locally queued data is preserved for retry, with sync left disabled.
  Repeating the command after a partial success treats an already-missing
  zone as success.

Before using cloud erasure, disable Nexus cloud sync on **every** previously
paired device. A different signed-in device holding old local records can later
create a new zone and re-upload those records when its user manually enables
sync. The application cannot remotely disable other devices.

This action deletes only Nexus's dedicated CloudKit zone in the configured
Apple private database; it does not touch iCloud Drive, photos, unrelated apps,
or independently saved local clipboard entries. Cloud-side behavior requires
a signed Apple Developer build and live-account verification. SQLite logical
deletion does not guarantee forensic overwriting of SSD/WAL snapshots or backups.
