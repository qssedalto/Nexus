# Nexus / task.md clipboard development: consolidated acceptance

**Status:** development candidate only; **not a signed or installed production release**.
This branch aggregates the stacked draft Pull Requests for the existing macOS
Nexus and the separate universal iPhone/iPad clipboard client. It does not
replace the installed Mac application, migrate live data, deploy a Worker,
enable iCloud entitlements, or merge into main.

## Source-implemented functionality

### Clipboard P0
- User-consented pasteboard observation for file URLs, text and encoded images.
- Local SQLite operation history, restart persistence, retention options,
  individual deletion, unpinned cleanup and permanent collection protection.
- Image bytes and safe bounded thumbnails with content/type deduplication and
  cache cleanup when final operation reference is removed.
- Native macOS bottom shelf with cards, file/Quick Look previews and
  source-app **foreground observation**, explicitly **unverified**.
- Historical copy-again, explicit paste requests, plain-text option, original
  clipboard-change-count race protection, Accessibility/focus guards.
- User-opted-in RTF and a strict offline safe HTML typography subset; no
  original RTF/HTML, attachments, remote images or web content in preview cache.
- Explicitly fenced offline code highlights, link classification without
  network fetching, and bounded lazy image/document previews.
- Existing Nexus/Finder services, Bundle IDs, production Cloudflare endpoints
  and data storage are preserved by default.

### Clipboard P1
- Real-time filtered history search, Chinese/English text, file name,
  source-app and date filters; optional pagination for older results.
- An indexed SQLite history path with automated synthetic 30,000-record
  regression and optional 100,000-record profiling. No hardware SLA inferred.
- Favorites/pins, permanent named collections, drag-to-add, ordered membership,
  stable card colors and independent collection history.
- User-editable Carbon global shelf shortcut with conflict rollback; focused
  only collection switching and search focus on supported macOS versions.
- Native menu-bar quick recent/pinned entries and explicit pause/resume.
- Hover/keyboard/fullscreen/multiple display geometry is implemented, but
  physical input/AX/Retina/Spaces appearance is still a device acceptance gate.

### CloudKit P2
- Private-zone versioned CKRecord encoder/decoder with strict identity,
  payload-size and logical revision validation.
- Offline-first SQLite outbox, mutation-specific acknowledgements, bounded
  incremental remote pages and transactional change tokens.
- Download-before-upload merging, payload-free delete tombstones, retry-safe
  merge, explicit token reset and manual consent-based staging.
- Separate text/name/path permissions all default off; images and file bytes
  are not uploaded by this metadata-only implementation.
- Manual Mac sync/CloudKit zone action and safe local-only import of remote
  metadata, collections and membership ordering without upload loops.
- Universal iOS/iPadOS app source with explicit foreground clipboard import,
  independent offline local SQLite text history, search, copy, delete and
  consent-gated CloudKit metadata transfer. Simplified Chinese and English
  app resources plus separate unsigned simulator build.
- Privacy-minimized local diagnostics keep only last successful manual sync
  time and bounded counts, not credentials, text, image bytes or server tokens.

## Automated gates (CI, not physical-device acceptance)

The GitHub Actions workflow builds the macOS Swift package tests, Python API,
Worker API, the isolated unsigned macOS app and Finder extension, NSServices
and ServicesOnly compatibility prototypes, and the unsigned universal iOS
simulator target. Review the latest check results on the **final integration
branch**, not just older stacked PRs. If any job is pending, canceled or
failed, mark the candidate unverified and resolve it before merging.

For an isolated local macOS build, consult plans/04-testing-release-plan.md
and the GitHub Actions workflow. Do not run release installation scripts on
the currently working system during source validation.

## Outstanding external/manual gates

1. Apple Developer Team and actual CloudKit container provisioning, with
   separate test bundle identity and CloudKit entitlements/profiles.
2. Authenticated Apple Account tests on two Macs and real iPhone/iPad:
   concurrent edits, retention/deletions, sign-out, page-token expiry,
   network loss, duplicate replay, restored collections and permission denial.
3. Actual macOS Finder, iCloud Drive local/online-only, OneDrive file
   provider, large >100GB packages and right-click menu ordering acceptance.
4. Real Accessibility-authorized Quick Paste to third-party applications,
   including after focus loss, user clipboard changes, and Control-click.
   A posted synthetic Cmd+V is NOT proof the target accepted the paste.
5. Native visual checks on light/dark mode, external negative-origin displays,
   Retina scaling, full-screen Spaces, iPhone/iPad size classes and VoiceOver.
6. Actual high-volume history benchmarks with realistic filenames/files and
   periods of sleep/wake. Synthetic benchmark success is not a device SLA.
7. Live service staging with separately provisioned identity/HTTPS/D1 or
   SQLite credentials, security review and rollback; never deploy over
   unrelated existing production Workers without express approval.
8. Signed distribution, App Group migration, Launch-at-Login / Finder Sync
   upgrade and user-data rollback on an isolated test installation.
9. Advanced HTML/web page title remote retrieval, faithful arbitrary RTF,
   full code language grammars, binary images/files CloudKit transfer, and
   all Apple/platform APIs that Nexus cannot safely access remain deliberately
   unsupported or limited.

## Safety rules for release reviewers

- Clipboard text, source paths, images and iCloud content require their
  **separate, explicit** consent. Do not implement contradictory task.md
  wording that silently collects sensitive content or removes retention.
- No background iOS pasteboard watching, remote WebKit thumbnail downloads,
  secret copying into debug logs, or automatic clipboard uploads.
- Readonly CI builds must not install/replace Nexus, register additional
  Finder services or mutate a live user's database or Apple account.
- Keep all stacked PRs in Draft until their exact head checks and device gates
  have been reviewed. Do **not** merge main as a substitute for testing.
- If a user requests deletion of material already uploaded to CloudKit,
  disabling sync alone does not erase the private-zone copies; implement a
  separate authenticated purge and verify it before promising erasure.

## Result classification

**Implemented and automated-tested** means the source compiles and regression
tests passed. **Manually verified** requires real documented device evidence.
**Released** requires signing, migration/rollback and explicit install approval.
No part of this document equates those three categories.
