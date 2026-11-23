# BlueStacks 5 clean gaming integration

Date: 2026-10-01

## Goal

Treat an official BlueStacks 5 installation as a supported Android runtime underneath the existing RustDesk emulator layer. The integration must inventory and launch instances, expose a conservative cleanup UI, keep BlueStacks updates working, and never patch or replace BlueStacks binaries.

## Safety boundary

- Discover BlueStacks through registry/config/install metadata rather than a fixed path.
- Keep Hyper-V, graphics/runtime dependencies, updater components, emulator services, signatures, games, anti-cheat behavior, and device integrity untouched.
- BlueStacks configuration writes are limited to keys that exist in the currently installed `bluestacks.conf`; unknown or removed keys are skipped.
- Optional component uninstall is never part of a profile apply. It requires its own explicit UI action and a registered Windows uninstaller.
- Android package cleanup is allowlist-first. Core Android, Google, BlueStacks integration, networking, media, input, shared-folder, clipboard, account, and ADB packages are protected.
- Restore reverts only values, startup entries, shortcuts, and Android package states changed by this application, and only when the current state still matches what this application applied.

## Architecture

`src/server/emulator/bluestacks/` owns the provider and management adapter. `BlueStacksProvider` implements the existing `EmulatorProvider` seam for discovery/start/readiness/ADB. Rich inventory and cleanup operations live beside it so provider-specific concepts do not leak into the generic emulator model.

The existing Flutter `mainGetCommon` / `mainSetCommon` bridge carries JSON inventory and action payloads to a Windows-only BlueStacks Settings tab. No new transport, service, or privilege channel is introduced.

## Discovery

The adapter reads `HKLM\\SOFTWARE\\BlueStacks_nxt` (including registry views) for `InstallDir`, `DataDir`, `UserDefinedDir`, and `Version`, with uninstall metadata and a validated environment/config override only as fallback. An install is valid only when the official player and bundled ADB executable are present.

Instances are derived from `bst.instance.<id>.*` keys in `bluestacks.conf`. Display name, framebuffer size, DPI, ADB port, notification settings, ad package metadata, and Android flavor/version are normalized. Running state is matched from `HD-Player.exe` command lines containing the provider instance id.

The same inventory lists BlueStacks-related Windows services, startup entries, desktop/start-menu shortcuts, Multi-instance Manager, BlueStacks X, BlueStacks Services, and an independently installed BlueAI entry where present.

## Supported cleanup

Settings that correspond to current BlueStacks 5 Preferences and are present in the installed config may be changed idempotently:

- gameplay ads: `bst.enable_programmatic_ads=0`
- Smart Downloads: `bst.enable_smart_downloads=0`
- Store on start: `bst.launch_store_on_boot=0`
- automatic app desktop shortcuts: `bst.create_desktop_shortcuts=0`
- per-instance desktop notifications: `bst.instance.<id>.enable_notifications=0`

Clean Gaming also disables only startup entries confidently tied to BlueStacks Services/X/BlueAI and hides BlueStacks desktop launcher shortcuts by reversible rename. Start-menu shortcuts remain available by default.

Feature/capability keys such as `bst.feature.*` are inventory signals and are not rewritten merely because a similarly named user preference exists.

## Profiles

- Standard: disable gameplay ads, Smart Downloads, and Store-on-start while otherwise staying close to stock.
- Clean Gaming: Standard plus desktop notifications, automatic app shortcuts, safe optional startup entries, and BlueStacks desktop launcher shortcuts.
- Custom: caller supplies any subset of the same supported reversible actions.

BlueStacks X and independently installed BlueAI may be shown as optional/promotional components. Removal is a separate destructive action and is never triggered by Standard, Clean Gaming, or Custom profile apply.

## Restore and update handling

A serialized journal is stored in RustDesk configuration. For every touched config key it stores original and applied values; for startup entries it stores the original registry value; for hidden shortcuts it stores original and disabled paths; for Android apps it stores only packages disabled by this tool. Applying the same profile twice must not overwrite the original snapshot.

The version associated with the last applied cleanup is stored separately. If the detected BlueStacks version changes, inventory reports that cleanup should be reviewed/reapplied. Reapply re-runs the same guarded supported actions against the new config; missing/renamed keys remain untouched.

## Android packages and launch workflow

When BlueStacks ADB access is already enabled, `HD-Adb.exe` is used only against the instance's local `127.0.0.1:<port>` endpoint. Package inventory separates protected Android/Google/BlueStacks packages, user apps, optional/promotional packages, and unknown packages. The known GameVantage package discovered in the current 5.22 installation (`com.uncube.gamevantage`) is optional/promotional. Unknown packages are never removed automatically.

Per-instance default packages are stored in RustDesk configuration. Launch uses BlueStacks' own desktop-shortcut command shape (`HD-Player.exe --instance <id> --cmd launchApp --package <package> --source desktop_shortcut`). When ADB is available, the adapter additionally verifies Android readiness/package presence and can launch through supported Android package-manager mechanisms.

The provider exposes start when the official player executable exists. Stop/restart are not advertised until a supported per-instance BlueStacks stop mechanism is identified; force-killing BlueStacks is outside this integration.

## UI

Add a Windows-only `BlueStacks` Settings tab with Installation, Instances, Startup, Optional Components, Android Apps, Cleanup, and Advanced sections. Clean Gaming is the recommended preset. Destructive component/package uninstall buttons always use an explicit confirmation dialog.

The UI must show unsupported/unavailable controls instead of guessing, and it must surface update/reapply and restore status from inventory.

## Verification

Rust tests cover config parsing/editing, instance normalization, process-instance matching, profile selection, restore guards, component/package classification, launch arguments, and destructive-action protection. Flutter tests cover inventory decoding/profile state. A Windows smoke test validates discovery against the locally installed BlueStacks without mutating it.
