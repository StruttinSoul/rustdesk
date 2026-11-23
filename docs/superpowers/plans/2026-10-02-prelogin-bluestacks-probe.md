# BlueStacks pre-login startup compatibility probe

The user requires cold-boot startup before any Windows account signs in. Automatic sign-in is outside scope. This is an experimental compatibility probe, not a claim of official BlueStacks headless support.

The installed official BlueStacks 5.22.280.1026 uses Hyper-V/Vulkan. Its kernel driver starts automatically; both HD-Player processes currently run in console session 1. Its helper scheduled task requires an interactive user. The current RustDesk host is portable, with no installed service.

RustDesk's existing Windows service launches a SYSTEM host into the console session even at the login screen. A thin, opt-in hook in that host can attempt to launch the unmodified official HD-Player into `winsta0\\default`, requesting minimized startup. This avoids running the graphics app in service session 0 or changing Windows sign-in. Actual Android/game rendering before sign-in still requires a cold-boot test.

Implementation stays inline, preserving all existing dirty work and the deployed phone build. No agents, automatic sign-in, security changes, emulator binary modification, forced emulator shutdown, or automatic reboot.

- [x] Add red/green tests for selected stopped-only startup and fail-closed configuration.
- [x] Add a Windows-only boot module, disabled unless explicitly configured under an administrator-protected HKLM key. Keep provider/runtime and ordinary startup paths unchanged.
- [x] Build and verify a separate host package; preserve the running host.
- [x] Prepare an administrator setup/disable tool using the existing RustDesk service installer, with BlueStacks discovery/signature checks and configuration backup.
- [x] Verify tests, packaging, source correspondence, and the final regression surface.
- [ ] Enable only with successful administrator setup; verify before-sign-in Android video/control on a later cold boot. Never reboot the user's active games automatically.

Sources: Microsoft Task Scheduler logon types (`TASK_LOGON_INTERACTIVE_TOKEN` requires an already logged-on user), Microsoft Interactive Services (session isolation), and the project's existing `src/platform/windows.rs` service/console-launch implementation. Lack of documented BlueStacks headless support does not prove the console-service experiment will fail or succeed.

Verification: 90 emulator tests passed, 8 native integration tests ignored; release build passed in 3m37s. Packaged DLL load and all 94 host file checksums passed. Source archive contains 1004 files, including current dirty integration and the new boot module/setup tool. Previous deployed host and Android2070 artifacts were preserved. New DLL SHA256: fd985fc61abd990c7b06eb2afdf45d39cd146deae115130eb71c02659f3ad8fb.

Read-only OSLink inspection found its automatic LocalSystem service in session0, session1 helper children, and a user-owned main app plus Windows Run entry. Its official background-operation documentation and LDPlayer CLI do not establish pre-login game boot. Comparison recorded in docs/prelogin-bluestacks-probe.md. No OSLink/LDPlayer changes made.

Administrator setup subsequently created the matching RustDesk service and requested both selected player launches in console session 1. This was during a signed-in session, not cold-boot acceptance. Current read-only inspection confirms the startup selection is absent and RustDesk is stopped/disabled. The historical last-run report does not prove current readiness. No intentional reboot or re-enablement was performed.

Continuation ruling: the user stopped crash investigation and returned to this project. Continue inline code/package review; do not restart the disabled host while the new runtime-testing decision is pending. Corrected Enable to accept only this probe's disabled service (same path, SYSTEM account, receipt and matching library); set automatic startup before restarting and restore disabled startup if enablement fails. Existing automatic services retain their path; unrelated services remain rejected. Four isolated PowerShell checks passed, including failure rollback, without modifying the real service. The existing emulator test binary passed 86 server tests with 8 native tests ignored. Only the setup script and documentation changed in this continuation; Windows/Android runtime binaries remain unchanged.
