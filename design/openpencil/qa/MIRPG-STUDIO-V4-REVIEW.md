# MIRPG Remote — Studio V4 visual review

Date: 2026-10-12  
Scope: Six mobile design proposals at 393 × 852. **Production Flutter/RustDesk implementation unchanged.**

## Design direction

- Light gray and white for workspace navigation, restrained blue for actions, green for live/connected status.
- Matching charcoal dark theme on every artboard, with elevated cards, readable light typography, and brighter on-dark status accents. Illustration/video areas retain their original appearance.
- Offline gallery has a persistent Light/Dark switch and follows the system color preference until the visitor makes a choice.
- Future app implementation: **Settings → Appearance → System (default), Light, Dark**. Follow Android's current theme in System mode; retain the explicit preference across restarts and apply changes without disconnecting active streams.
- Dark canvas only for immersive Android video and controls directly surrounding the feed.
- Clear distinction between host connectivity, individual screen streams, and an interrupted preview.
- Editable vector navigation and session icons instead of placeholder letters.
- The Windows session includes fit/readable/180% presets, a mini-map, precision controls, and a left-side view switcher.
- The Android session retains the dedicated system-button rail for Back, Home, Recents, and Keyboard.
- Six screens in each theme: Home, All screens, Android session, Windows session, Codex, and Recovery.

## Verification on the editable OpenPencil document

- Native OpenPencil CLI created and saved 6 editable artboards (489 nodes).
- Full six-screen PNG exported and reviewed visually. Individual PNGs exported at 2×.
- Geometry checker: **6 artboards; 0 flags** for text clipping, screen-bound violations or overlapping text boxes.
- OpenPencil lint: **0 color-contrast errors** on both the light and dark variants after correcting contrast and rail glyph colors.
- Dark variant geometry checker: **6 artboards; 0 flags**.
- Remaining prototype warnings: small labels, undersized nonessential glyph targets, hardcoded colors. Adopt shared tokens and use proper minimum touch targets during implementation; this concept is not an accessibility certification.
- OpenPencil desktop live/MCP inspection was unavailable in the preceding design session; these exports use the working headless CLI.
- The dark variant is created from a copy of the light .fig using `build-studio-v4-dark.js` so individual screen dimensions and interactions align.

## Important limits

Desktop and MapleStory imagery is purpose-built vector **illustration**, not an actual live feed. The design proposes live thumbnails, but connectivity, frame pacing, emulator control, LAN routing, keyboard, and Codex streaming were **not tested** as part of this design task.

This is a visual review proposal. Do not modify production UI until the design is accepted.

## Files

- `../MIRPG-Studio-V4.fig`: native editable OpenPencil design
- `../MIRPG-Studio-V4-dark.fig`: native editable dark design
- `../MIRPG-Studio-V4-Preview.html`: offline clickable gallery
- `../exports/MIRPG-Studio-V4-all.png`: complete overview
- `../exports/MIRPG-Studio-V4-all-dark.png`: complete dark overview
- `../exports/MIRPG-Studio-V4-{home,screens,android,windows,codex,recovery}.png`: six 2× artboards
- `../exports/MIRPG-Studio-V4-{home,screens,android,windows,codex,recovery}-dark.png`: six 2× dark artboards
- `MIRPG-Studio-V4-lint.json`: full lint findings
- `MIRPG-Studio-V4-dark-lint.json`: full dark lint findings
