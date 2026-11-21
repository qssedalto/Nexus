# task.md implementation and acceptance ledger

Source of truth: [task.md](../task.md), 1,450 lines. This ledger describes actual evidence in this GitHub repository; it does not replace or silently rewrite the specification.

## Existing implementation inspected

| Area | Existing repository evidence | Remaining verification / limitations |
| --- | --- | --- |
| Finder path copy | `Sources/SlashgrabFinderSync/FinderSync.swift`, `PathCopyAction`, `AppState` | Preserve currently installed version; verify Finder right-click in local, external, iCloud-only, and OneDrive directories on real macOS |
| NSServices/iCloud entry | `Sources/Slashgrab/NexusServiceProvider.swift` registers `NSApp.servicesProvider` at runtime | Main app `Config/Slashgrab-Info.plist` does not currently declare a complete `NSServices` array. Registering one blindly may duplicate Finder Sync copy commands. Single-entry design and macOS submenu behavior require real Finder evaluation |
| System services UI | `SystemServicesView.swift` scans installed app bundles for services and treats unknown fields as unknown | No public per-third-party-service management API established; any global menu expansion change needs explicit consent, backup and rollback |
| Keyboard/mouse | `InputMonitor.swift`, `InputStatisticsStore.swift`, `InputStatisticsView.swift` | Media, Fn/Globe, additional HID devices, lock keys, permissions, sleep resume, long-term pressure and millisecond fidelity require hardware tests |
| Input sync | `NetworkSyncView.swift`, `Server/nexus_api.py`, `Server/worker.js`, `Server/schema.sql` | Verify live qsseda.com authentication, idempotence, transfer recovery, UTC queries and restored totals, not only source availability |
| Clipboard operations | `OperationStore.swift`, `ClipboardMonitor.swift`, `OperationTimelineView.swift` | Passive monitoring can only record **observed** clipboard changes, not a third-party application's actual originating event or successful file paste |
| Branding | Visible Nexus strings and project configuration `project.yml` | Preserve legacy bundle/group/data identifiers by design; verify Finder extension registration after a new signed build |

## This PR: concrete additions

- [x] Original, bottom-floating **Clipboard Shelf** in SwiftUI, opened from the existing menu-bar popover; horizontal cards, kind filters, local search, pinning and re-copy actions
- [x] Text clipboard history with an **independent, opt-in** persisted setting, using the existing SQLite operation store
- [x] Image-only clipboard observations saved as **metadata only**, without reading pixels or fabricating a source URL
- [x] Preserve one-to-many file/URL operation items and top-level path metadata without recursive folder-size scans
- [x] Separate detected clipboard change timestamps from confirmed Nexus clipboard writes; no fabricated completion/duration fields
- [x] Reuse the existing feedback popover for observed copy activity, without calling unconfirmed paste attempts successful
- [x] Add text/image filters to millisecond operation timeline, and include the selected upper millisecond boundary
- [x] Migrate partially upgraded SQLite databases without dropping historical rows
- [x] Add regression tests and macOS Swift/Xcode CI workflow
- [ ] Verify changes via successful final GitHub macOS CI run
- [ ] Install a development-signed candidate on an isolated test path and run complete real-device acceptance

## Not completed by this PR

- [x] Isolated, opt-in `ServicesPrototype` build with a single static NSServices entry and its own Finder Sync contextual menu compiled off; CI checks registration, code flags and unchanged normal Debug build
- [x] Opt-in global Services submenu preference controls with confirmation and exact integer/unset backup/restore (source + build checked; **no runtime preference mutation tests**)
- [ ] Real macOS iCloud Drive / OneDrive Finder test proving a **single visible** entry across local/cloud folders and determining first-level vs submenu placement
- [ ] Full per-key/per-device HID coverage including hardware F21-F24, Globe/Fn, uncommon side buttons and media keys
- [ ] End-to-end external copy **and paste completion** evidence; shortcuts alone cannot prove a paste succeeded
- [ ] Dedicated folder-size background calculation with explicit cancellation and no blocking Finder operations
- [ ] Operation-history API sync schema, permission-based full text/path upload, stable IDs, retry/restore and server deployment
- [ ] Real-time, permission-aware system-wide paste success notifications, where macOS exposes a genuine completion signal
- [ ] Device and browser integration acceptance (iCloud, OneDrive, macOS Finder services, large .pvm packages, sleep/wake)
- [ ] Full millisecond event-source verification, time-zone/DST testing and long-running performance measurements

## Non-regression requirements

Do not modify the existing installed application or its user database. Keep existing Bundle IDs, App Group, Finder extension, bilingual localizations and settings. Never disable SIP, inject Finder or claim a shortcut is proof of completion. File and image cards never load binary previews, and UI pin IDs are kept in local UserDefaults only.

## How to continue

Implement the remaining items incrementally on focused branches. Keep claims tied to verifiable Swift tests and an actual signed macOS installation. PRs stay in draft until their CI passes, and no automatic deployment should replace the user's working installed app.
