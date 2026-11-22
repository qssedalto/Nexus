# Nexus independent sync build tracks

This repository maintains two deliberately separate and experimental synchronization tracks. Neither build overwrites `Nexus.app`. The free edition is displayed as `Nexus Drive.app` without a developer badge; its internal development-variant identifier keeps storage isolated. Both must be built and tested before use.

## Free iCloud Drive track

- **Free Drive prototype:** branch `feat/icloud-drive-folder-sync`, PR #73. Select an existing iCloud Drive `NexusClipboardSync` directory in the Mac app (and iOS app when installed from Xcode). No CloudKit entitlement is requested. The folder is not selected automatically.
- **CloudKit provisioned prototype:** branch `feat/cloudkit-provisioned-track`, PR #74. Requires an actual Apple Developer Program team, registered CloudKit container, authorized App ID, and matching provisioning profile. It never enables itself in ordinary builds.
- Both tracks keep separate, provider-specific local SQLite journals and preferences. Do not copy their journal files between versions.
- A regular, installed `Nexus.app` and its Finder extension are not replaced implicitly.

## Build the version on this branch

From the repository directory:

```zsh
bash Scripts/build_drive_dev.sh --verify
```

Both wrappers deliberately use unique app identifiers:
- Nexus Drive: `com.qssedalto.nexus.drive.dev`
- Nexus CloudKit Dev: `com.qssedalto.nexus.cloudkit.dev`

Run without `--verify` only after build and signing have been checked on the intended Mac. The actual `CloudKit` test build must be signed for its **new** unique App ID, not an old `com.qssedalto.nexus.dev` provisioning profile.

## Free folder protocol limitations

- **Encrypted folder protocol v2:** sync change files are AES-256-GCM sealed using a randomly generated 256-bit pairing key stored in the device Keychain. The same 64-hex-character key must be entered on each device. Never place the key in the synchronized folder. Deleting the key makes old records unreadable. All clipboard sync permissions default OFF. The protocol still needs real multi-device verification.
- The initial folder transport supports text and metadata only. Original image/file bytes do not transfer in this branch.
- The File Provider/iCloud Drive system handles actual file propagation. Sync now only reads/writes local files; it does not guarantee another device has already downloaded them.
- This is not an Apple CloudKit private database. Removing folder records is a best-effort File Provider deletion operation, not a verified remote purge or forensic erase.
- The iOS client must be built and installed on a physical device via Xcode; a personal team may require periodic free provisioning. iOS never silently reads the clipboard in the background.
- No track is safe to label production-ready until macOS CI, iOS CI, signed-device tests, cross-device merge, conflicts and deletion tests pass.
