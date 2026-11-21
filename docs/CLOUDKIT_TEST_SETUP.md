# Opt-in private CloudKit configuration (NOT enabled in default Nexus builds)

The default Nexus app, Finder extension, Release, Debug, ServicesOnly and CI
builds **do not have CloudKit entitlements** and cannot upload the clipboard.
Do not change this default or replace a working installation implicitly.

The Swift code includes an explicit privacy/settings tab and an adapter for a
private CKRecordZone named NexusClipboard. To exercise it on a Mac with
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
   change pages, click Sync again. No scheduled network work is active.
6. On a second Mac signed for the *same* container and Apple Account, repeat
   setup and fetch. Check deletion tombstones, conflict recovery, duplicate
   retries, sign-out, permission revocation, network loss, file-only records,
   Unicode filenames and the Finder extension independently.

Privacy and scope:

- CloudKit stores operation **metadata only by default**. Copied text,
  file/collection names and local file paths require independent opt-ins.
- Original clipboard image data and file bytes are **never uploaded**.
  Remote file records are descriptive metadata, not valid file references
  on other devices. The remote history screen only copies text that was
  explicitly authorized.
- Current transport expects logical deletion tombstones rather than physically
  deleting a record from the CloudKit zone. It does **not** reconcile every
  retention-cleanup deletion automatically, and does not provide a verified
  server-side purge operation. Do not market it as fully synchronized deletion.
- Disabling permission prevents further sync, but previously uploaded data
  remains in the Apple private database until separately deleted.
- macOS CI exercises the codec, deterministic merge, offline journal,
  mock transport and unsigned build. It **cannot** verify real Apple account
  access, CloudKit server permissions or end-to-end device synchronization.
- This integration does not create an iPhone/iPadOS binary or automatically
  install any application on another device.
