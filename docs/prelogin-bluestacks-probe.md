# BlueStacks before-sign-in compatibility probe

This opt-in Windows experiment attempts to start selected official BlueStacks 5 instances after a cold boot, before any Windows account signs in. It does not enable automatic sign-in or change Windows login protection. BlueStacks remains an official, signed installation. No emulator binaries, images, Hyper-V settings, game files, or security software are changed.

BlueStacks does not document a supported headless/pre-login mode. A successful process launch alone does not demonstrate usable Android graphics, games, or remote control. The actual cold-boot test remains required.

## Comparison with installed OSLink and LDPlayer

Read-only inspection on October 2, 2026 found OSLink's `LDRemoteSvc` running automatically as LocalSystem in session 0. It had launched `ldremote.exe` and `ldremoteevent.exe` into console session 1. The main `ldremote.exe` was owned by the signed-in Windows user; ownership of the privileged helper was not readable from the unelevated inspection. OSLink also had a Windows Run entry invoking `ldremote.exe --pcstart`. This confirms a service plus desktop-agent design. It does not prove that an LDPlayer instance can boot and render before the first Windows sign-in. No OSLink/LDPlayer services, settings, account data, or binaries were changed.

The installed LDPlayer 9's documented `list2` command returned three stopped instances, including Android-ready state and player/VM process IDs. [LDPlayer's official command-line guide](https://www.ldplayer.net/support/introduction-to-ldplayer-command-line-interface.html) documents launch, app launch, ADB, and enumeration. [Its newer guide](https://jp.ldplayer.net/support/ldconsole-command-line-guide.html) does not document a pre-login launch guarantee; it also marks `globalsetting` unavailable, so older performance switches must not be assumed valid. [OSLink's features page](https://www.oslink.io/feature) advertises continuous background multi-instance operation while the PC remains on, without documenting cold-boot operation before Windows sign-in.

The applicable pattern is to keep a boot-started remote-access service separate from session-specific emulator handling, while using guest video/input rather than depending on visible emulator windows. RustDesk already supplies that service/session separation. The BlueStacks-specific compatibility probe below remains necessary; LDPlayer behavior cannot establish compatibility for BlueStacks Hyper-V/Vulkan.

## How it works

The normal RustDesk Windows service starts automatically and launches its host as LocalSystem in the console session. A Windows-only hook in that installed host waits 15 seconds, rediscovers BlueStacks, and launches only selected stopped instances. The official player is assigned `winsta0\default` and requested to start minimized, rather than being launched in service session 0 or on the Windows login desktop. BlueStacks may ignore the minimized request; this needs verification.

Running, booting, and unknown-state instances are left alone. Invalid configuration, missing instances, unsupported installations, and conflicting services fail safely. The worker rechecks its selection after the delay so disabling during that delay cancels startup. It never stops an emulator. It attempts each launch once per installed host startup; no crash/restart loop is added.

The privileged probe requires the official player in protected Program Files, with a valid BlueStacks/Now.gg signature at setup. It is disabled unless an administrator configures `HKLM\SOFTWARE\MIRPG\EmulatorBoot` (64-bit view). This key and `C:\ProgramData\MIRPG-EmulatorBoot` permit writes only by administrators and SYSTEM. No arbitrary executable or command can be specified in the instance selection.

## Install and enable

The local test package contains `host`, `boot-selection.json`, and `setup_prelogin_bluestacks.ps1`. `Enable.cmd` requests Windows UAC and uses the selected instance IDs in the JSON file. It installs this custom host through RustDesk's existing installer, including the matching guest capture helper. It preserves RustDesk's existing authentication import path. Installing/restarting the service briefly disconnects RustDesk; it leaves BlueStacks running.

The initial local selection is `Tiramisu64` and `Tiramisu64_2`. The setup tool revalidates those IDs against the installed BlueStacks configuration. An unrelated existing RustDesk service or installation is not overwritten.

Explicitly running Enable can restore automatic startup for a disabled service only after the existing installation is identified as this probe build. If enablement fails, the previous disabled startup mode is restored. Inspect and Disable do not re-enable the service.

`Inspect.cmd` displays setup and last launch status without elevation. `Disable.cmd` requests UAC and restores the startup selection recorded before setup. It refuses to overwrite subsequent manual changes. It leaves running instances and RustDesk's remote-access service alone. RustDesk can be removed later through its normal uninstaller if desired.

## Required cold-boot acceptance test

Current local status on October 2, 2026: the installed host previously requested both selected player launches in console session 1. This was after Windows sign-in, so it does not establish cold-boot compatibility. The startup selection is now absent and RustDesk is stopped with startup disabled. The saved launch report is historical; inspect current service/configuration state before interpreting it. Re-enabling and the planned cold-boot test remain outstanding.

1. At a planned restart, keep everyone signed out. Do not sign in to make the test pass.
2. Allow roughly two minutes for Windows, virtualization, and Android to boot.
3. From the existing test phone app, authenticate to the same PC. Verify BlueStacks instances have live changing previews before anyone signs in.
4. Open each instance. Confirm Android input, orientation, navigation buttons, and game graphics work. Verify PC-monitor switching remains available, subject to Windows login-screen capture limitations.
5. After the before-sign-in checks, sign in normally and confirm the existing instances remain usable without duplicates or ownership errors. Test a later locked session as well.
6. Use `Inspect.cmd` to collect `C:\ProgramData\MIRPG-EmulatorBoot\last-run.json`. `launch_requested` only means Windows accepted process creation; it is not proof of Android readiness or live video.

If BlueStacks fails under the pre-login SYSTEM context, disable the probe. Do not work around failures by weakening Windows login protection, disabling security software, enabling interactive services, or modifying BlueStacks. A normal logged-on session with minimized players and a locked PC remains a separate option, not an equivalent cold-boot result.

## Implementation and regression surface

New startup logic is contained in `src/server/emulator/boot_windows.rs`. Existing `src/server/emulator.rs` only declares the Windows-only module. Existing `src/server.rs` adds one guarded startup hook in its server branch. Portable hosts, ordinary user hosts, non-Windows hosts, and installed hosts without an enabled selection retain their previous behavior. The existing BlueStacks provider, phone UI, streaming protocol, token-launch code, and service installer are unchanged.

The protected setup state records only this integration's configuration. Existing BlueStacks cleanup settings, manual user changes, emulator service behavior, and updater settings are not reverted or changed. Windows/BlueStacks updates may invalidate this experimental compatibility and must be retested rather than blocked.
