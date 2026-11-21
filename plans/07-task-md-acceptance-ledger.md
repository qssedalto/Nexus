# Nexus task.md implementation and acceptance ledger

Source of truth: [task.md](../task.md), **1,450 lines** as read in the repository on 2026-11-21. The source does **not** contain any lines 1451–1750. Earlier ledgers mistakenly attributed a separate iPhone/iPad/CloudKit implementation requirement to nonexistent lines; that has been corrected here. The original request to take design inspiration from Paste is separate from the actual file specification.

## Implemented code in the stacked development branches

| Requirement / module | Concrete source or PR | Evidence and boundaries |
| --- | --- | --- |
| Native Finder path copy | `SlashgrabFinderSync/FinderSync.swift`, `PathCopyAction.swift`; PRs #1, #2, #8 | Uses supported Finder Sync on selected folders; provides separately compiled `ServicesOnly` for a **single** NSServices copy action. Default release does **not** add duplicate NSServices. User-device Finder/iCloud menu placement unverified |
| macOS Services manager | `NativeServicesCatalog.swift`, `SystemServicesView.swift`; PRs #2, #8 | Read-only nested app/workflow enumeration, own Finder menu toggle, optional global submenu threshold with exact backup and restore. macOS does not expose supported APIs to dynamically move one arbitrary third-party service to the first menu level or to rewrite other apps' declarations |
| Passive keyboard/mouse monitoring | `InputMonitor.swift`, `HIDConsumerMonitor.swift`, `HIDConsumerUsage.swift`; PRs #7, #14 | Quartz/AppKit/IOHID callbacks, special/lock/F21–F24/Consumer keys, side mouse buttons and wheel, repeat policy, no text/raw sequence capture, source/device-model classification with unavailable details marked unknown. Fn/Globe/vendor-specific HID and device permissions require physical tests |
| Long-term SQLite statistics | `InputStatisticsStore.swift`; PRs #7, #13, #14 | Buffered writes, idempotent migration, partial schema support, integrity/backup/CSV, exact UTC timestamp query, per-category/device trends, per-key counts, configurable ranges, source time index and five-confirmation deletions. Profiling multi-year real-world load pending |
| Statistics dashboard | `InputStatisticsView.swift`; PR #7 | Total count cards, special-key rankings, detailed key trends, hour/day/week/month chart, today/yesterday/7d/30d/month/year/all/custom ranges and special-key diagnostics |
| iCloud statistics backups | `InputCloudBackupController.swift`, `InputStatisticsStore.restoreBackup`; PRs #7, #15 | Explicit folder choice and opt-in backup, separate stable Mac UUID folders, logical SQLite online snapshots, explicit restore/merge and independently opted-in other-Mac imports. **PR #15 CI requires its final passing run**. This is iCloud **Drive file** synchronization, not an implemented CloudKit record backend |
| Clipboard file/text/image history | `ClipboardMonitor.swift`, `OperationStore.swift`; PRs #1, #4, #6 | Independent text consent; image type/path metadata only; top-level folder/package metadata with unknown sizes, no thumbnails/binary or recursive Finder scans; pinned records and named permanent collections |
| Clipboard card shelf and quick-paste | `ClipboardShelfView.swift`, `ClipboardHotkeyController.swift`; PRs #1, #5, #6, #12 | Native floating horizontal cards, search/types, pin/collections/reorder, copy-again, global shortcut presets, click/keyboard selection, explicit Accessibility-aware paste request, recent-only query plus older favorites; successful third-party paste cannot be confirmed from a shortcut |
| Unified operation time line | `OperationTimelineView.swift`, `OperationStore.swift`; PRs #1, #3, #9, #11 | Distinct file, text, image, drag/drop, native path copy and paste request states. Times are event/detected/completed when known, never fabricated; filter and display millisecond ranges |
| Files/folders metadata & size | `FolderSizeScanner.swift`; PR #3 | One operation to many top-level items. File/package URLs recorded without reading binary; explicitly initiated cancellable bounded background folder size scan; path and size remain untouched when unavailable/cancelled |
| Local retention and permissions | `PrivacySettingsView.swift`; PRs #4, #10 | Separate text/files, paste-request, cloud operation metadata/path/body, pause, exclusions, age/count retention with permanent favorites protected. No undisclosed cloud uploads |
| Operation-history network API | `Server/nexus_api.py`, `Server/worker.js`, `Server/schema.sql`, `NetworkSyncView.swift`; PR #3, in-progress capability handshake | Authenticated versioned metadata batches, stable UUID/device keys, partial acknowledgement, idempotent server upserts, range query and paginated restore, per-device delete, independent consent and redaction. **Actual qsseda.com production deployment/credential provisioning not performed** |
| Start at login | `AppState.swift`, `AppDelegate.swift`; PR #13 | New installations enable; established user preference (including disabled) is preserved; app currently installed is not changed |

## Validation state

PRs #1–#14 each have a full passing macOS CI run after fixes, including Swift package tests, Python reference API tests, Node Worker+D1 tests, XcodeGen, regular App plus Finder extension, and single Services prototype/build checks. The latest passing evidence through #14 is [Run #44851380934](https://github.com/qssedalto/Nexus/actions/runs/44851380934).

PR #15 (iCloud Drive backup restore) initially had a failing local-duplicate import test and its latest CI must be verified before marking complete. Later stacked PRs inherit this issue until fixed.

## Remaining outside proven source-code implementation

- [ ] **macOS device acceptance:** native Finder/iCloud Drive (local, only-online), OneDrive, configured Mouser side keys, Fn/Globe/media/F21–F24 across HID models, Accessibility focus, multi-display, sleep/wake and >100GB packages.
- [ ] **Production cloud deployment:** a dedicated Nexus endpoint, isolated D1/SQLite storage, identity-specific authentication, token provisioning, safe rollback and live HTTPS origin are required. Existing `qsseda-work` / `qsseda-auth` deployments are unrelated and must not be overwritten.
- [ ] **OS-imposed limits:** a third-party application does not generally report completed paste or real originating clipboard app; Apple does not give apps a public API to force a single arbitrary third-party service into Finder's top-level menu. Only observed requests and documented service registration are possible. No fabricated statuses.
- [ ] **Remote CloudKit record sync / iOS clients:** these are not explicitly demanded by the 1,450-line file and are not claimed implemented. iCloud Drive file backups/merges and authenticated qsseda API are the actual modules in this work.
- [ ] **Release safety:** real Apple Development signing, launch-at-login, legacy App Group and Finder Sync migration in an isolated test install; user has not asked to replace their currently installed version.

## Nonregression contract

Do not change installed apps, production signing credentials, original Bundle IDs or App Group contents. Do not bypass SIP/TCC, inject Finder, remap Mouser or synthesize a paste just to verify success. Do not record typed text/password fields, silently upload clipboard bodies, overwrite old databases, or treat an observed shortcut as proof of an operation.

No stage should be marked “finished” merely because a CI compilation succeeded; deployment, OS permission, visual UI behavior and unsupported APIs are separate evidence categories.
