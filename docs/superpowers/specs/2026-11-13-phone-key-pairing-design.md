# Phone key pairing: password-free login from a trusted phone (design)

Date: 2026-11-13. Status: approved by the user on 2026-11-13 (after a builder review). Not committed.

## Intent

The user's Galaxy phone should open Aperture and land straight in atlas (the Windows host): no ID to type, no password prompt. Atlas trusts that phone because the user said so once, and can stop trusting it at any time.

The ID part already works: the Android home page auto-connects to the last remote ID on launch (`flutter/lib/mobile/pages/home_page.dart:52`). This design removes the password prompt, only at home and over WireGuard.

## Goals

- A paired phone logs in to atlas with no password when it reaches atlas over the encrypted LAN listener (TCP 21120), at home or through WireGuard.
- Pairing is one tap on the phone during a session already authenticated with the password.
- Atlas lists the paired phones and can remove any of them. Removal takes effect on the next login.
- Anywhere else (public relay, mobile data without WireGuard), behaviour is exactly as today: password prompt, or the saved password if the user ticked "Remember password".

## Non-goals

- Password-free login over the public relay or rendezvous path.
- Using Android Keystore or hardware-backed keys (possible later).
- Pairing several hosts from one screen, or syncing trust between PCs.
- Changing 2FA, approve-mode, click-to-accept or permission rules.
- Self-hosted hbbs/hbbr and WireGuard setup (separate task in the handoff).

## Anti-goals (a failure even if it works)

- Anything that trusts a claim the phone makes about itself (hardware ID, device name, IP address) instead of a proof only the paired phone can produce.
- A key login accepted on an unencrypted stream, on the legacy direct port 21118, or on any path other than the 21120 listener.
- A captured login that can be replayed later.
- Old phones or old hosts losing the ability to log in with the password.
- Changes to the shared upstream `hbb_common` submodule.

## Constraints (from the code and project rules)

- Password login is a per-connection challenge: atlas sends `Hash { salt, challenge }`, the client answers with SHA256-derived bytes (`src/client.rs` `handle_hash`; `src/server/connection.rs` `validate_password`).
- The protocol messages Aperture owns live in `libs/base/protos/message.proto`. `LoginRequest` ends at field 17. Unknown fields are ignored by old builds, so a new optional field is backward compatible.
- The 21120 listener (`src/lan.rs` `serve_secure`) only runs when `aperture-secure-lan` = `Y`. It accepts only private or loopback source addresses and always runs the secure handshake (`secure = true`). It currently passes `ConnectionMeta::default()`, so the connection does not know which listener it came from.
- The phone's LAN fast path (`src/client/lan_fast_path.rs`) only tries addresses found by LAN discovery, filtered to private IPv4 addresses matching the saved ID. It pins atlas's identity from an earlier verified connection, and rejects the stream unless it is secured. Discovery does not work through WireGuard, so today a WireGuard phone falls back to the relay.
- The existing 2FA "trusted devices" feature keys on `hwid`, which the client sends about itself. It is not reused.
- Project rules: Rust 1.75.0; no blocking in async code; no unthrottled logging in per-packet loops; the smallest coherent change; installs, firewall changes and phone changes each need the user's go-ahead.

## Approaches considered

1. **Phone key (chosen by the user).** The phone holds a signing key. Atlas stores the public keys of paired phones and accepts a signature over its per-connection challenge in place of the password, only on the 21120 listener. Trusts the phone itself. Needs a host DLL and a phone APK.
2. **Trust the tunnel address.** Atlas skips the password for the phone's fixed WireGuard IP. Little code, but it trusts an address rather than the phone, depends on a WireGuard setup that is not decided yet, and does nothing (or is spoofable) on home Wi-Fi. Rejected.
3. **Remember password on the phone.** No code, but still a password. The user wants real pairing. It stays available as the off-network fallback.

## Design

### Keys and the proof

- The phone generates one Ed25519 signing key pair on first use (sodiumoxide `sign`, already a dependency). It is stored in the phone's local Aperture config, in app-private storage, and is never sent anywhere. The public key identifies the phone.
- At login, after receiving `Hash`, the phone signs this message:
  `"aperture-device-login-v1" || host_id || salt || challenge || conn_type`
  with fields length-prefixed so they cannot run together. `challenge` is fresh per connection, so a captured proof is useless later. `host_id` stops a proof made for one PC from working on another.
- New optional field in `LoginRequest` (`libs/base/protos/message.proto`):
  `DeviceProof device_proof = 18;` with `message DeviceProof { bytes public_key = 1; bytes signature = 2; uint32 version = 3; }`.
- The phone sends the proof only when all of these hold: it has a key, it believes it is paired with this host ID, and the stream is a LAN fast-path stream (secured, identity-pinned). Today the client cannot tell that after connecting: `lan_fast_path::start` returns the same `(stream, direct, pk, …)` shape as a normal direct connection (`src/client/lan_fast_path.rs:90-94`). The builder must carry a "came through the LAN fast path" flag from there to `handle_hash`.
- When it sends a proof, the phone sends it **instead of** the password (empty `password`) and does not show the password box yet. So the phone knows which method was used: success means the key worked.
- Key login only applies to the main remote connection (`ConnType::DEFAULT_CONN`), because the LAN fast path only runs for that (`lan_fast_path.rs:47`). File transfer, terminal and other separate connections keep their current login behaviour. `conn_type` stays in the signed message as a guard.

### When the key is not accepted (decided after review; my call)

- If the proof is present but not accepted (unknown key, bad signature, not on 21120, unsecured stream), atlas replies with a new login error, `LOGIN_MSG_DEVICE_KEY_REJECTED`. It does **not** fall into the empty-password path, which would otherwise open a click-to-accept request on atlas (`connection.rs` `try_start_cm(..., false)`).
- On that error, the phone clears its "paired with this host" flag and then runs the normal password flow on the same connection: saved password if there is one, otherwise the password box. After removal on atlas, the phone recovers by itself and **Trust this phone** reappears after the next password login.
- Old host: a phone is only marked paired after a new host accepted the pairing message, so a proof only reaches an old host if atlas was downgraded after pairing. In that case the old host sees an empty password and shows its normal accept prompt. Accepted as a rare downgrade case.

### Host check (atlas)

- `ConnectionMeta` gains a field (e.g. `secure_lan: bool`) that `serve_secure` sets to `true`. Nothing else sets it.
- In the `LoginRequest` branch of `on_message`, before the password checks: if `device_proof` is present and **all** of these hold, atlas treats the login as authenticated:
  1. the connection came from the 21120 listener (`secure_lan`);
  2. the stream is secured (negotiated key in place);
  3. the public key is in atlas's paired-phone list;
  4. the signature verifies over the exact message above, using this connection's salt and challenge.
- Otherwise the proof is ignored and the existing password, approve-mode and click-to-accept logic runs unchanged.
- A proof whose key is on the list but whose signature fails counts as a failed login in the existing failure throttle (`check_failure` / `update_failure_with_scope`). An unknown key does not count; it is just ignored.
- Approve-mode: key login is allowed in the same cases where a password login is allowed. Under click-only mode it is refused like a password.
- 2FA, when enabled on atlas, still applies after a key login (my call: key login replaces the password, not the second factor).
- Audit: new `ConnAuditPrimaryAuth::DeviceKey`, and one info log line per key login that names the phone (not per packet).

### Pairing

- On the phone, in the connected-PC screen (`target_dashboard_page.dart`), add **Trust this phone**, shown only when the session is authorized with a password and the phone is not yet paired with this host.
- Tapping it sends a new message carrying the phone's public key and a display name (phone model by default). Atlas accepts it only on an authorized session whose primary authentication was a password (temporary or permanent), not on a key login. It stores the key, name and time, and replies OK. The phone records "paired with <host ID>".
- Pairing may happen over any secured session, including through the relay. The password has already proven the user. Using the key still requires the 21120 path.
- A pairing is never silent: atlas writes an audit/log entry and the phone appears at once in the **Trusted phones** list in settings. No Windows toast (it would need a new IPC path into the desktop session for little gain, since pairing already requires the password). My call after review.

### Trusted-phone list on atlas

- Stored in atlas's service-side config as a small JSON list: public key (base64), name, added time, last-used time. Only the service process writes it; the desktop UI lists and removes phones through new IPC requests to the service (in the same style as the existing `trusted-devices` IPC in `src/ipc.rs`), not through the general option sync, so a pairing and a removal at the same moment cannot overwrite each other. My call after review. The `last-used` update must not write config on every packet; once per login is enough.
- Desktop settings (`flutter/lib/desktop/pages/desktop_setting_page.dart`, Security tab) gets a **Trusted phones** section: name, added, last used, and a **Remove** button per phone. Removing a phone takes effect on that phone's next login. Sessions already open stay open (my call; matches how changing the password behaves today).
- The phone gets **Forget pairing** for this PC in the same place as Trust, which deletes its local "paired" flag (and leaves the key, which is harmless).

### Reaching atlas over WireGuard

- When a LAN fast-path connection succeeds, the phone stores that address (e.g. `<atlas-ip>:21120`) in the peer's config, next to the verified identity it already stores.
- When discovery finds no candidate, the phone also tries that stored address within the existing budget (250 ms per candidate, 750 ms total). It is still identity-pinned and must be secured, so a wrong host at that address is rejected exactly like today.
- This works as-is if WireGuard ends on the router and routes the tunnel into the home LAN: the phone reaches `<atlas-ip>:21120` from a private tunnel address, which the listener already accepts.
- If WireGuard ends on atlas itself, it may not: `serve_secure` binds only the default interface's private IPv4 (`src/lan.rs:366-369`), and Windows can drop packets that arrive on the WireGuard adapter addressed to the LAN adapter's IP. That case needs the listener to also bind the WireGuard address, which belongs to the separate WireGuard task, not this one.

### Compatibility

| Phone | Host | Result |
|---|---|---|
| New, paired | New | Key login on 21120; password elsewhere |
| New | Old | Old host ignores field 18; password as today |
| Old | New | No proof sent; password as today |
| New, removed from atlas | New | "Key rejected" reply; phone clears its paired flag, then saved password or prompt |
| New, paired, atlas downgraded | Old | Old host shows its accept prompt (rare; accepted) |

## Testing

- Host unit tests: valid proof accepted only with `secure_lan` + secured stream + listed key; rejected for wrong challenge, wrong host ID, wrong conn type, unlisted key, unsecured stream, non-21120 connection, and a replayed proof from an earlier connection. Failed signature by a listed key counts toward the failure throttle.
- Pairing tests: accepted on password-authorized sessions; refused on key-authorized and unauthorized sessions; list add, remove and persist.
- Client tests: proof is built only on a secured LAN fast-path stream; the stored address is tried when discovery is empty and is rejected when the identity does not match (extending the existing `lan_fast_path` tests).
- Existing suites stay green: the focused `emulator` suite (167 at this point) and the LAN fast-path tests.
- On the devices, with the user's go-ahead: pair; reconnect at home with no prompt; remove on atlas, then see the prompt again; mobile data without WireGuard shows the prompt. WireGuard is tested when the tunnel exists.

## Delivery

- One host DLL (through the existing updater, with a new pinned hash) and one phone APK. Both need the user's go-ahead to install. `aperture-secure-lan` is already `Y` on atlas, so no firewall change is expected for home use. WireGuard reachability is part of the separate WireGuard task.
- Batch 2 is staged but not installed. This work builds on the same tree, so its DLL will include batch 2.

## Left to the builder

- Exact names: the new message type for pairing, the config key for the trusted list, the phone-side key and paired-flag storage keys.
- Where the trusted list is stored (prefer client-owned config in `libs/base`; do not change `hbb_common`).
- How the phone's display name is chosen and whether it can be edited.
- UI layout details of the two small additions, following the existing screens.
