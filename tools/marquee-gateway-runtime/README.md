# Marquee Gateway runtime supervisor mirror

This directory is the reproducible source mirror for the Windows Gateway supervisor that MIRPG's RustDesk integration inspects and controls. The deployed runtime remains owned by `C:\Users\gregr\MarqueeGatewayRuntime`; these files are source/evidence, not a second supervisor and are never launched from this repository.

Mirrored from the deployed runtime source on 2026-10-06:

- `runtime_manager.py` — SHA-256 `AA7E5616E67AFB5BC7D43291FA020DACF86BFA9D96B0A7971D1ACE620CC5E807`
- `runtime_configuration.py` — SHA-256 `A71A215789BBD686B9765ECE03101E2652FD066A993555A513242FF05D4226BD`

The mirror deliberately excludes runtime state and secrets: `*.dpapi`, setup cookies/codes, bearer tokens, pairing material, `gateway.db*`, `process.json`, `exit.json`, executables, logs, generated certificates, and other mutable deployment data must never be copied into this repository.

## RustDesk management bootstrap

The supervisor opts the owned Gateway child into RustDesk management with the child-only environment variable `MARQUEE_RUSTDESK_MANAGEMENT=1`. A compatible Gateway creates a separate random management bearer and prints it only to the supervisor's private stdout pipe. The supervisor combines that bearer with the setup TLS leaf fingerprint and loopback setup address, machine-DPAPI protects the bootstrap, and stores it under `.rustdesk-management\rustdesk-management.dpapi` in a directory restricted to SYSTEM, Administrators, and the supervisor's Windows identity.

Before every owned child start the prior RustDesk bootstrap is deleted, so a restarted child cannot inherit the previous child's bearer. The ordinary Gateway setup/playback credentials remain separate and are not exported to RustDesk.

## Deployment and rollback

Source changes here do not deploy or restart the live Gateway. During an approved maintenance window, first build and verify a Gateway binary that understands the explicit management opt-in, then compare these mirror hashes with the intended live supervisor sources before replacing them. Restart only through the existing owned supervisor lifecycle; never start a second supervisor or broadly terminate Python/Gateway processes.

For rollback, restore the immediately previous `runtime_manager.py`, `runtime_configuration.py`, and compatible Gateway binary as one generation, then restart through the same supervisor ownership path. Protected runtime state is retained; do not restore or copy DPAPI/token files between generations. After either deployment or rollback, re-enumerate the child PID/process creation identity, setup listener, management bootstrap, Silo state, capacity, and IMDb status before declaring the runtime ready.
