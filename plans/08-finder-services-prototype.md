# Finder / iCloud Drive — single-entry NSServices prototype

This is the second implementation increment for [task.md](../task.md), sections 2–3.

## Current conclusion

Apple supports static services declared by an app's `NSServices` key and implemented by an `NSApp.servicesProvider` selector. That does **not** mean the command can force itself into Finder's first-level context menu. On macOS the Services submenu/layout is controlled by the system; the global `NSServicesMinimumItemCountForContextSubmenu` preference can affect *all* services at once, not a selected service individually. The exact behavior requires an actual Finder test.

The existing production Finder Sync menu already works in supported local folders and must remain untouched while experimenting. This PR intentionally does **not** add a new NSServices registration to Debug, Release or Local.

## What is implemented

- `ServicesPrototype` is a **separate, unsigned-by-default, noninstalled build configuration** with a distinct bundle identifier and application group.
- Only this app declares one `NSServices` entry: `Copy Selected Paths`, with `NSSendFileTypes = public.item` and `NSRequiredContext = {}`.
- This configuration alone defines `NEXUS_SERVICE_PROTOTYPE`, so its bundled FinderSync extension returns no path-copy contextual menu. The source of Finder Sync is preserved.
- The existing `NexusServiceProvider` handles the native callback and records the operation through `PathCopyAction` as `detectionMethod = nsservices`.
- The service menu title is **static**. It cannot dynamically change from PDF to Word or folder names based on selection through the service declaration; multiple overlapping service declarations could introduce duplicate menu items.
- Existing language resources provide English/Chinese menu text.

## Build safely

After checking out this development branch on a Mac with Xcode and XcodeGen:

```zsh
bash Scripts/test_services_prototype.sh
```

This command compiles **into a separate DerivedData directory only**, then validates the built Info.plist. It does not move an app to `/Applications`, register services, run `pbs`, modify Finder preferences, run a signed installer or touch the currently installed Nexus.

CI also builds the original Debug app before running this prototype, to protect the baseline.

## Manual macOS acceptance matrix — pending

Do not run this test by installing the prototype alongside the existing active Finder Sync command, as two *different applications* could still advertise copy-path operations. Use a dedicated macOS test account/VM or explicitly disable the existing extension for a limited test, and restore its previous state afterward.

| Finder context | Registered? | Visible? | First or second level? | File URL accurate? | Copy works? |
| --- | --- | --- | --- | --- | --- |
| Internal local folder/file | Not tested | Not tested | Not tested | Not tested | Not tested |
| External Macintosh SSD | Not tested | Not tested | Not tested | Not tested | Not tested |
| iCloud Drive root | Not tested | Not tested | Not tested | Not tested | Not tested |
| iCloud Drive subfolder | Not tested | Not tested | Not tested | Not tested | Not tested |
| iCloud online-only placeholder | Not tested | Not tested | Not tested | Not tested | Not tested |
| OneDrive File Provider | Not tested | Not tested | Not tested | Not tested | Not tested |
| Desktop / Documents | Not tested | Not tested | Not tested | Not tested | Not tested |
| Multi-selection + mixed file types | Not tested | Not tested | Not tested | Not tested | Not tested |
| CJK/quotes/whitespace in paths | Not tested | Not tested | Not tested | Not tested | Not tested |

On a controlled test machine check Finder menu, Services submenu, copied string, whether file URL is valid without downloading file bytes, and whether the existing FinderSync action was absent. Do not assume an online-only iCloud URL will be available without materialization; record unavailable instead of inventing one.

## Global Services submenu preference — opt-in UI

The **System Services** settings tab now includes a collapsed **Global Services menu layout** section. It displays the *actual global preference*, not the app's own defaults. The user must explicitly choose one of the following, click **Apply system-wide…**, and then confirm the effect on other applications:

- **Follow system default** — remove only this global key when it is currently set.
- **Expand all Services where possible** — set the global threshold to integer `999`.
- **Group Services in submenu** — set the global threshold to integer `1`.

Before the first modification, Nexus backs up both the integer value and whether the key was **unset**, using the app's UserDefaults. **Restore previous global value…** asks for separate confirmation, restores the exact saved integer/unset state using the supported `defaults` command and only then removes the snapshot. It refuses to overwrite an existing preference whose type is not an integer. Failure preserves the snapshot. Neither app launch nor the prototype build writes this global preference, and Nexus never restarts Finder automatically.

This is **not per-service control**. It may change menu placement for many apps, and macOS retains ultimate control of what appears. Restored snapshots are scoped to the bundle ID that made the initial change; keep that app's preference domain until restoration.

Read-only terminal inspection:

```zsh
defaults read -g NSServicesMinimumItemCountForContextSubmenu 2>/dev/null || echo "System default (not explicitly set)"
```

Do not use `defaults write -g` manually unless you understand that it affects other apps' Services menus.

## Source references

- [Apple — NSServices](https://developer.apple.com/documentation/bundleresources/information-property-list/nsservices)
- [Apple — Services Properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html)
- [Apple — Providing a Service](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html)

## Acceptance status

This is a build-and-registration prototype, **not yet a verified solution for iCloud Drive's first-level menu**. Its purpose is to test the single-entry design without risking the existing installed version or duplicating Finder menus.
