# Nexus independent sync build tracks

This repository maintains two deliberately separate and experimental synchronization tracks. Neither build overwrites `Nexus.app`. Both must be built and tested before use.

## Provisioned CloudKit track

- **Free Drive prototype:** branch `feat/icloud-drive-folder-sync`, PR #73. Select an existing iCloud Drive `NexusClipboardSync` directory in the Mac app (and iOS app when installed from Xcode). No CloudKit entitlement is requested. The folder is not selected automatically.
- **CloudKit provisioned prototype:** branch `feat/cloudkit-provisioned-track`, PR #74. Requires an actual Apple Developer Program team, registered CloudKit container, authorized App ID, and matching provisioning profile. It never enables itself in ordinary builds.
- Both tracks keep separate, provider-specific local SQLite journals and preferences. Do not copy their journal files between versions.
- A regular, installed `Nexus.app` and its Finder extension are not replaced implicitly.

## Build the version on this branch

From the repository directory:

```zsh
NEXUS_CLOUDKIT_CONTAINER_ID='iCloud.YOUR_REAL_CONTAINER' NEXUS_CLOUDKIT_PROVISIONING_PROFILE='/absolute/path/to/profile.provisionprofile' SIGNING_MODE=development APP_IDENTITY='Apple Development: YOUR_NAME (TEAM_ID)' bash Scripts/build_cloudkit_dev.sh --verify
```

Both wrappers deliberately use unique app identifiers:
- Nexus Drive Dev: `com.qssedalto.nexus.drive.dev`
- Nexus CloudKit: `com.qssedalto.nexus.cloudkit.dev`

Run without `--verify` only after build and signing have been checked on the intended Mac. The actual `CloudKit` test build must be signed for its **new** unique App ID, not an old `com.qssedalto.nexus.dev` provisioning profile.

## Free folder protocol limitations

- **No Nexus end-to-end encryption in v1.** The selected folder contains JSON changes, and users should not enable sensitive text or file paths until encryption has been implemented and reviewed. The app defaults to upload permission OFF.
- The initial folder transport supports text and metadata only. Original image/file bytes do not transfer in this branch.
- The File Provider/iCloud Drive system handles actual file propagation. Sync now only reads/writes local files; it does not guarantee another device has already downloaded them.
- This is not an Apple CloudKit private database. Removing folder records is a best-effort File Provider deletion operation, not a verified remote purge or forensic erase.
- The iOS client must be built and installed on a physical device via Xcode; a personal team may require periodic free provisioning. iOS never silently reads the clipboard in the background.
- No track is safe to label production-ready until macOS CI, iOS CI, signed-device tests, cross-device merge, conflicts and deletion tests pass.
