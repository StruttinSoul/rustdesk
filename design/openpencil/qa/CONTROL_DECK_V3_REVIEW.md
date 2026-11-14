# MIRPG Remote — Control Deck V3 review

**Status:** Editable OpenPencil proposal. The Flutter app is unchanged.

## New design language

- **Personal Control Deck:** ink-dark surfaces (#0B1418), sea-glass emphasis (#79E3CA), restrained copper (#DDBA85), angled signal motifs, and precise editorial typography.
- Flat-edged device surfaces, numbered navigation and fine linework replace rounded Material card stacks.
- The UI adapts to the remote target: immersive Android with a separate control rail, readable Windows with trackpad tools, and a compact Codex timeline.
- Inspiration: SwiftDesk's simple connection workflow, OSLink's live-view indexing, Splashtop's mobile controls and Jump Desktop's device-readable display mode. The visual execution is MIRPG-specific.

## Resolved V2 collisions

| V2 issue | V3 result |
| --- | --- |
| Emulator thumbnails under bottom tabs | Both Home cards end at y=737; dock starts at y=765. |
| Crowded switcher previews and labels | All five target rows are 87 dp high with separate image and text regions. |
| Missing Android button icons | Back, Home, Recents and Keyboard use a dedicated 69 dp rail with editable vector shapes. |
| Windows switcher overlaps desktop content | 48 dp switch tab floats in a reserved left gutter; readable Explorer window is inset. |
| Codex composer covered by bottom navigation | Composer ends at y=750, 15 dp before the dock. |
| Recovery alternate view obscured by dock | Alternate view ends at y=737, 28 dp before dock. |
| Generic error dialog | Explicit host-online state, stream-stale indicator, retry and view switch. |

## Verification

- Six editable 393×852 OpenPencil artboards, exported as a composite and six separate PNGs.
- Built with OpenPencil headless CLI 0.15.1.
- Geometry checker: 0 intersecting text pairs, text outside immediate parent, or text outside screen boundaries.
- OpenPencil lint: 0 errors. Warnings remain for hardcoded prototype colors, smaller decorative labels and some heuristically small touch targets. Before Flutter implementation, bind shared color/text tokens and provide minimum 48dp hit regions for actionable controls.
- Imagery and telemetry are illustrations; live emulator/PC frames and FPS/latency were not verified.
- No production changes, APK deployment, Git push or release.

## Next step for implementation

Use the current Flutter, RustDesk and emulator architecture. Make sure actual streams and touch targets match each concept; test fresh/stale preview states, Windows readably scaled mode, portrait Android navigation and Codex activity with real mobile screenshots.
