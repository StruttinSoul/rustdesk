# Google Android Emulator in Aperture's emulator list (running-only) — design (2026-11-14)

## Why
The user is trialling Google's Android Emulator (AVD `Aperture_Trial_Play35`, Android 15 with Play Store) as a BlueStacks alternative. Today it is only reachable through the Desktop view; they want it listed and streamed like the BlueStacks instances.

## Decision (user's)
**Running-only** (option 2 of 2). Aperture lists and streams a Google emulator while it is running; starting and stopping it stay on the PC. The full provider (start/stop from Aperture) was declined for now.

## Design
### Host (`src/server/emulator/avd.rs`, provider id `avd`)
- Detected when a default ADB server (port 5037) is running; no SDK or profile lookup (the service runs as SYSTEM).
- Discover: `adb devices` → each online `emulator-N` serial → `adb -s emulator-N emu avd name`. A serial that answers with an AVD name is a Google emulator; one that doesn't (BlueStacks, LDPlayer aliases) is skipped. One `getprop` reads boot state and Android version.
- Target: stable id `avd:<name>` (AVD names are `[A-Za-z0-9._-]`; anything else is skipped), display name = AVD name with `_` as spaces, state Ready or Booting, ADB endpoint = the serial.
- `resolve_adb`/`refresh` re-find the serial by name (the port can change between runs).
- start/stop/restart return an error telling the user to start/stop it on the PC; capabilities: adb only.
- Registered next to BlueStacks and LDPlayer in `remote_windows::targets`; live previews allowed for `avd`; the BlueStacks-marker check that guards LDPlayer also guards `avd`.
- The global `adb devices` call shares the existing ADB runner (same timeout, no console window).

### Phone
- The dashboard lists `avd` instances as guest targets next to BlueStacks; the emulator page labels them "Android Emulator".
- Shutdown stays BlueStacks-only.

## Non-goals
- Starting/stopping AVDs from Aperture, listing stopped AVDs, launching the game by default.

## Verification
- Rust unit tests for parsing `adb devices`, `emu avd name`, the getprop output, and name → stable id.
- Flutter test: an `avd` instance appears as a dashboard target.
- On device (after install, with the user's go-ahead): the emulator shows in the list and streams.
