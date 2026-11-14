# MIRPG Remote

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

The current user controls a Windows gaming PC and its BlueStacks instances from an Android phone. The requested experience is a live overview of those instances and PC monitors, with quick switching into fullscreen control.

## Product Purpose

Make the Windows PC and its Android gaming instances accessible through one authenticated RustDesk connection. BlueStacks should feel like a managed backend runtime rather than a separate interface the phone user must navigate.

## Operating Context

The existing project uses a Flutter mobile interface and Rust host/client integration. The Windows host runs an official BlueStacks 5 installation. The current test phone is a Samsung SM_S938W. The phone may connect on the same LAN or over the internet.

The user selected automatic reconnection to the last PC, subject to normal RustDesk authentication. Work on this project stays in the current chat without agents.

## Capabilities and Constraints

- The requested dashboard includes BlueStacks instances and individual PC monitors. LDPlayer is excluded from this dashboard.
- Running targets have continuous live video previews. Stopped BlueStacks instances have an explicit Boot action.
- Fullscreen control has a target switcher on the left. Android Back, Home, and Recents controls belong in the right black margin, clear of the game.
- Direct connectivity is preferred when available, with relay fallback and an honest Direct/Relay indicator. Being on the same network alone does not prove the selected transport is local.
- Preserve existing RustDesk authentication, permissions, desktop behavior, and the recent emulator streaming fixes.
- BlueStacks remains official and updateable. Do not modify its binaries, games, code signatures, virtualization, or anti-cheat behavior.
- Cleanup and optional component removal follow the existing explicit-action and restore requirements; this dashboard does not expand cleanup authority.

## Evidence on Hand

- User reference: `C:/Users/gregr/Downloads/1000026833.jpg`, showing the game view and controls that currently cover game content.
- User reference: `C:/Users/gregr/Downloads/1000026835.jpg`, showing the desired OSLink-style live overview and Boot workflow.
- The existing emulator integration supplies guest capture, touch control, Android navigation, discovery, and startup.
- Preview performance and actual LAN routing of the final implementation require testing; no OSLink-equivalent performance measurement has been established.

## Product Principles

1. Show real live state and make the next action obvious.
2. Keep navigation controls outside remote content.
3. Prioritize responsive fullscreen control while keeping visible previews live.
4. Preserve the supported runtime and authenticated connection boundaries.
5. Report failures and connection routes accurately rather than implying success.
