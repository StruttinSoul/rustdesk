# MIRPG Remote — SwiftDesk-inspired UI exploration V2

**Status:** Review and editable design proposal only. Production Flutter unchanged.

## References distilled into our interface

- **SwiftDesk:** calm, minimal one-tap access to the saved computer. Adapt the low-friction presentation; don't copy branding or stealth-mode behavior.
- **OSLink:** live thumbnails and explicit Boot/Open for each Android emulator.
- **Splashtop:** fast monitor switching, compact hidden session controls, mouse/keyboard/display options.
- **Jump Desktop:** desktop content must remain readable on a phone; optionally investigate phone-matched virtual displays where supported.
- **AnyDesk:** gesture-accessible session actions, without permanently covering the remote screen.

## Six mockups (393 × 852 dp)

1. Launchpad: one-tap monitor and BlueStacks entries.
2. Switcher: two Windows monitors and three Android guests, including stopped/bootable guests.
3. Immersive BlueStacks: fullscreen portrait, right Back/Home/Recents, left switcher.
4. Windows: readable zoom, mouse/touch controls, keyboard and quick switching.
5. Codex: readable conversation, collapsed command activity, explicit task status.
6. Recovery: show PC online separately from video preview errors; retry and switch target.

The editable document is `../MIRPG-Remote-SwiftDesk-V2.fig`; exported PNGs live in `../exports/SwiftDesk-V2-*.png`.

The new six-screen OpenPencil study remains a **proposal**. Source app code was not modified. Lint completed with zero errors and prototype warnings (small labels, hardcoded colors and touch target sizes). For production, use `mirpg_remote_theme.dart` variables, verify 48dp hit boxes, verify live frame timestamps and real telemetry, and avoid static FPS/latency claims. Implement all functionality in the current Flutter/RustDesk architecture after a design selection.

**Important:** The polished browser concept and the editable OpenPencil sketch are companion explorations, not pixel-identical. On-device parity testing remains pending.
