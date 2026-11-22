# Nexus dual synchronization editions (experimental)

Nexus maintains two **independent** development tracks. Neither should replace an installed working Nexus automatically.

| Track | Repository branch | Credentials and transport | Current readiness |
| --- | --- | --- | --- |
| Free folder sync | `feat/icloud-drive-folder-sync` | User-selected `NexusClipboardSync` folder (iCloud Drive syncs files); AES-256-GCM encrypted changes, independent 256-bit key in device Keychain | Experimental; needs CI and real multi-device acceptance |
| Apple CloudKit | `feat/cloudkit-provisioned-track` | Apple Developer Program, a registered CloudKit container, compatible profile, explicit per-category consent | Original opt-in implementation; live provisioned tests unverified |

## What the free track currently does

- Mac and iOS/iPadOS can select the **same named folder** using OS-provided file pickers.
- Generate a random 256-bit secret on one device, then enter the exact 64-digit hex key on each other device. The secret must be shared separately; it is **never stored in iCloud Drive**.
- Records are written only after consent and explicit initialization. UUID-named `.nxe` files are AES-GCM authenticated ciphertext, located in `encrypted-changes`. Authenticated decryption happens before records are processed.
- The local SQLite journal and deterministic conflict/tombstone model are reused; the app does not rely on automatic entitlement provisioning.
- Binary image/file payloads have **not** been adapted to this folder protocol; do not treat placeholders as downloadable original files.
- iOS cannot silently monitor other apps' clipboards. The existing mobile UI only imports clipboard text after a direct user action.
- The existing macOS build and mobile Simulator build do **not** establish a signed physical-device distribution path. A free Personal Team may be used for on-device development within Apple's limits, but requires local Xcode provisioning and renewal.
- File Provider propagation is eventually consistent. Sync may be delayed, and this is **not** a verified, always-on, end-to-end cross-device solution until real-device acceptance.

## Security and privacy

- Category opt-ins remain off by default. Avoid transferring passwords, verification codes, or highly sensitive content.
- The local SQLite history and pending journal are not additionally encrypted by this folder transport; the device's disk-protection and local access controls still matter.
- The pairing secret is stored in Keychain and never in the synchronized directory; anyone who obtains the key and encrypted documents can decrypt them.
- There is no key rotation/recovery protocol. Changing a key makes previous files unreadable unless they are re-exported under the new key.
- An iCloud Drive file deletion is not a verified server-side permanent purge; cached copies, version history, backups, and other devices may retain ciphertext. CloudKit has a separate private-zone deletion mechanism and must not be confused with file deletion.
- The end-to-end encryption claim covers the folder sync documents written by Nexus, not Apple's own File Provider internals or the local application database.

## First setup (future verified builds only)

1. On Mac, choose the existing iCloud Drive folder named `NexusClipboardSync`.
2. Generate a pairing key in the free folder-sync Settings and record it securely.
3. Initialize the folder, choose the data categories, and explicitly enable sync.
4. Prepare a bounded local page and press **Sync now**.
5. On iOS/iPadOS, install a separately signed build, select the same folder, enter the pairing key, then explicitly sync.
6. Verify the exact content, deletion behavior, conflict handling, and network-offline recovery on both devices.

**Never merge or distribute either edition merely because the source compiles.**
