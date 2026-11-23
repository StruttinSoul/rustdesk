# Phone Key Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A paired phone logs in to atlas with no password when it connects through the encrypted LAN listener (TCP 21120), at home or over WireGuard.

**Architecture:** The phone signs atlas's per-connection `Hash` challenge with an Ed25519 key. Atlas checks the signature against its list of paired public keys, only for connections accepted by `lan::serve_secure`. Pairing is a new message sent during a password-authenticated session. The list lives in the host's `Config` options, and the service process is its only writer.

**Tech Stack:** Rust 1.75.0 (sodiumoxide `sign`, protobuf in `libs/base`), Flutter 3.24.5, flutter_rust_bridge 1.80 (no new FFI functions; uses the existing `session_set_common`, `session_get_common`, `main_get_common` and `main_set_common`).

**Spec:** `docs/superpowers/specs/2026-11-13-phone-key-pairing-design.md`

## Global Constraints

- Toolchain: Rust 1.75.0 only, at `%USERPROFILE%\.rustup\toolchains\1.75.0-x86_64-pc-windows-msvc\bin`. Set `RUSTUP_TOOLCHAIN=1.75.0-x86_64-pc-windows-msvc`, `VCPKG_ROOT=%LOCALAPPDATA%\MIRPG\windows-cache-sdk`, `LIBCLANG_PATH=C:\DevTools\vcpkg\downloads\tools\clang\clang-15.0.6\bin`.
- Focused test recipe, written below as `FOCUSED <filter>`: `cargo test --release --lib --features flutter,hwcodec,vram --config profile.release.package.rustdesk.opt-level=0 --config profile.release.package.rustdesk.codegen-units=16 --no-fail-fast <filter>`.
- Do not change the `libs/hbb_common` submodule. Protocol changes go in `libs/base/protos/message.proto` only.
- No new crates. No new flutter_rust_bridge functions, so `generated_bridge.dart` is not regenerated.
- The working tree has about 140 uncommitted files of the user's work. Never reset, checkout, stash, clean or restore anything. **Do not commit.** Each task ends with a checkpoint: save `git diff` of the task's files to `target/phone-key-pairing-20261113/task-N.diff` and add one line to `target/phone-key-pairing-20261113/progress.md`.
- No install, no firewall change and nothing on the phone without the user's explicit go-ahead.
- No logging above `trace` in per-packet paths. At most one `info` line per key login or pairing.
- Signed message domain tag (exact): `aperture-device-login-v1`. Proof `version` = 1.
- New login error string (exact): `Device key not accepted`.
- Option and storage keys (exact): host list `aperture-trusted-phones`; phone secret key (LocalConfig) `aperture-device-sign-sk`; per-peer paired flag (PeerConfig option) `aperture-device-paired` = `Y`; per-peer last verified LAN address (PeerConfig option) `aperture-lan-last-address`.

## Review Focus

1. **A phone removed on atlas while its session is open, then reconnecting:** it must get the password path, not a hang and not an accept prompt on atlas. Covered by Task 3 `rejected_proof_replies_device_key_error_without_cm` and Task 6 `rejection_clears_paired_flag_and_retries_with_password`.
2. **A captured proof replayed on a new connection, or against another host ID:** must be rejected. Covered by Task 1 `proof_does_not_verify_for_other_challenge_or_host`.
3. **A proof arriving on the legacy direct port 21118, or through the relay:** ignored, with normal password behaviour. Covered by Task 3 `proof_ignored_off_secure_lan_listener`.
4. **A corrupted `aperture-trusted-phones` value (hand-edited or truncated JSON):** atlas must treat it as an empty list and keep password login working, not panic. Covered by Task 2 `corrupt_list_reads_as_empty`.
5. **Pairing the same phone twice, or from a key-authenticated session:** no duplicate entry; a key session cannot pair. Covered by Task 2 `adding_same_key_twice_keeps_one_entry` and Task 4 `pairing_refused_on_key_authenticated_session`.

---

### Task 1: Proof format and protocol fields

**Files:**
- Create: `src/aperture_device_proof.rs` (declared `pub mod aperture_device_proof;` in `src/lib.rs`)
- Modify: `libs/base/protos/message.proto` (`LoginRequest`, `Message` union)
- Modify: `src/client.rs:117-122` (new constant)

**Interfaces:**
- Produces:
  - Proto: `message DeviceProof { bytes public_key = 1; bytes signature = 2; uint32 version = 3; }`; `LoginRequest.device_proof = 18`; `message AperturePairDeviceRequest { uint64 request_id = 1; bytes public_key = 2; string name = 3; }`; `message AperturePairDeviceResponse { uint64 request_id = 1; bool ok = 2; string error = 3; }`; `Message` union `aperture_pair_device_request = 44`, `aperture_pair_device_response = 45`.
  - `pub const LOGIN_MSG_DEVICE_KEY_REJECTED: &str = "Device key not accepted";` in `src/client.rs`.
  - `pub fn proof_message(host_id: &str, salt: &str, challenge: &str, conn_type: i32) -> Vec<u8>`: the domain tag, then each field as a u32 little-endian length followed by its bytes (`conn_type` as its 4 LE bytes).
  - `pub fn sign_proof(sk: &sign::SecretKey, host_id: &str, hash: &Hash, conn_type: i32) -> DeviceProof` (version 1, detached signature).
  - `pub fn verify_proof(proof: &DeviceProof, host_id: &str, hash: &Hash, conn_type: i32) -> bool`: false for version ≠ 1, wrong key or signature length, or a bad signature.
  - `pub fn public_key_b64(pk: &[u8]) -> String` (the existing `crate::encode64`).

- [ ] **Step 1: Write the failing tests** in `src/aperture_device_proof.rs` `mod tests`:
  - `valid_proof_verifies`: generate a key pair, `sign_proof(sk, "<rustdesk-id>", &Hash{salt:"s",challenge:"c"}, 0)`, then `verify_proof(...) == true`.
  - `proof_does_not_verify_for_other_challenge_or_host`: the same proof verified with challenge `"c2"`, host `"999"`, or conn_type `1` → `false` in each case.
  - `fields_cannot_run_together`: `proof_message("ab","c","d",0) != proof_message("a","bc","d",0)`.
  - `wrong_version_or_lengths_rejected`: version 2, a 31-byte key or a 63-byte signature → `false`.
- [ ] **Step 2: Run** `FOCUSED aperture_device_proof`. Expected: compile failure (module missing).
- [ ] **Step 3: Add the proto fields, the constant and the module** with the signatures above.
- [ ] **Step 4: Run** `FOCUSED aperture_device_proof`. Expected: 4 passed. Then `FOCUSED emulator`. Expected: 167 passed, 0 failed (the proto change breaks nothing).
- [ ] **Step 5: Checkpoint** (task-1.diff, progress line).

### Task 2: Trusted-phone list on the host

**Files:**
- Create: `src/server/aperture_trusted_phones.rs` (declared in `src/server.rs`)
- Modify: `src/ipc.rs` (the `get_config` name branch near line 1037; the `Data` enum; the `Data` handler near line 1258)
- Modify: `src/flutter_ffi.rs` `main_get_common` (line 2704) and `main_set_common` (line 2807), desktop only (`#[cfg(not(any(target_os = "android", target_os = "ios")))]`)

**Interfaces:**
- Produces:
  - `#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)] pub struct TrustedPhone { pub public_key: String /* base64 */, pub name: String, pub added_unix: u64, pub last_used_unix: u64 }`
  - `pub fn parse(json: &str) -> Vec<TrustedPhone>` (corrupt or empty → empty list)
  - `pub fn list() -> Vec<TrustedPhone>` (reads `Config::get_option("aperture-trusted-phones")`)
  - `pub fn is_trusted(public_key: &[u8]) -> bool`
  - `pub fn add(public_key: &[u8], name: &str, now_unix: u64) -> bool` (true if newly added; an existing key keeps one entry and updates its name)
  - `pub fn remove(public_key_b64: &str) -> bool`
  - `pub fn touch(public_key: &[u8], now_unix: u64)` (sets `last_used_unix`; called once per key login)
  - Pure helpers that the above wrap and the tests use: `fn add_to(list: Vec<TrustedPhone>, ...) -> (Vec<TrustedPhone>, bool)`, `fn remove_from(...)`, `fn touch_in(...)`.
  - IPC: `get_config("aperture-trusted-phones")` returns the JSON; `Data::RemoveApertureTrustedPhone(String)` makes the service call `remove`.
  - FFI: `main_get_common("aperture-trusted-phones")` → JSON via IPC; `main_set_common("aperture-remove-trusted-phone", <base64 key>)` → sends `Data::RemoveApertureTrustedPhone`.

- [ ] **Step 1: Write the failing tests** (pure helpers, no global config):
  - `corrupt_list_reads_as_empty`: `parse("{not json")`, `parse("")` → `vec![]`.
  - `adding_same_key_twice_keeps_one_entry`: two `add_to` calls with the same key → `len() == 1`; the second returns `false` and the name is updated.
  - `remove_deletes_only_that_key`: two keys, remove one → the other remains; removing an unknown key returns `false`.
  - `touch_updates_last_used_only`: `last_used_unix` changes and `added_unix` does not.
- [ ] **Step 2: Run** `FOCUSED aperture_trusted_phones`. Expected: compile failure.
- [ ] **Step 3: Implement** the module, the IPC branch and variant, and the two FFI keys.
- [ ] **Step 4: Run** `FOCUSED aperture_trusted_phones`. Expected: 4 passed.
- [ ] **Step 5: Checkpoint.**

### Task 3: Key login on the host

**Files:**
- Modify: `src/server.rs:92-95` (`ConnectionMeta`) and `src/lan.rs` `serve_secure` (pass `ConnectionMeta { secure_lan: true, ..Default::default() }`)
- Modify: `src/server/connection.rs`: the `LoginRequest` branch of `on_message` (around 3222-3410), `ConnAuditPrimaryAuth` (361), and the `Connection` fields
- Test: `src/server/connection.rs` `mod tests`

**Interfaces:**
- Consumes: `verify_proof` (Task 1), `is_trusted` and `touch` (Task 2), `LOGIN_MSG_DEVICE_KEY_REJECTED`.
- Produces:
  - `ConnectionMeta.secure_lan: bool`, stored on `Connection` as `secure_lan`.
  - `ConnAuditPrimaryAuth::DeviceKey = 5`.
  - `fn device_proof_decision(secure_lan: bool, stream_secured: bool, proof: Option<&DeviceProof>, trusted: impl Fn(&[u8]) -> bool, host_id: &str, hash: &Hash, conn_type: i32) -> DeviceProofDecision` with `enum DeviceProofDecision { Absent, Ignored, Accepted, Rejected { counts_as_failure: bool } }`. `Ignored` = proof present but not on 21120 or the stream is not secured. `Rejected { counts_as_failure: true }` only for a listed key with a bad signature.
  - Also a pure helper `fn primary_auth_was_password(&self) -> bool` for Task 4.
- Placement in `on_message`: after the click-only approve-mode branch (so click-only refuses key login just as it refuses a password), and before `is_recent_session`. `Accepted` → set audit to `DeviceKey`, `touch`, one `info` log, then `send_logon_response_and_keep_alive` and `try_start_cm(..., self.authorized)` exactly like a password success (2FA handling stays inside that path). `Rejected`/`Ignored` with an empty password → `send_login_error(LOGIN_MSG_DEVICE_KEY_REJECTED)`, return `true`, and **no** `try_start_cm`. When `counts_as_failure`, run it through `check_failure(0)` / `update_failure_with_scope(failure, false, 0, FailureScope::Default)`. `Absent` → the existing code, unchanged.
- conn_type passed to verify: the `ConnType` the login request implies (`DEFAULT_CONN` = 0 when `lr.union` is `None`). Any other union gives a different value, so a proof made for the main connection cannot open file transfer or terminal.

- [ ] **Step 1: Write the failing tests** for `device_proof_decision`:
  - `accepted_on_secure_lan_with_listed_key`
  - `proof_ignored_off_secure_lan_listener` (`secure_lan=false` → `Ignored`)
  - `proof_ignored_on_unsecured_stream`
  - `unlisted_key_rejected_without_failure_count` (`Rejected{counts_as_failure:false}`)
  - `listed_key_bad_signature_counts_as_failure`
  - `no_proof_is_absent`
  - `rejected_proof_replies_device_key_error_without_cm`: if the existing test harness in `connection.rs` can drive `on_message` (see the tests near line 7965), assert the reply is a `LoginResponse` error equal to `LOGIN_MSG_DEVICE_KEY_REJECTED` and that no CM start was recorded. If it cannot, record that in the task report and cover it in Task 8's device test.
- [ ] **Step 2: Run** `FOCUSED device_proof_decision`. Expected: compile failure.
- [ ] **Step 3: Implement** the decision function, the meta field, the audit variant and the `on_message` branch.
- [ ] **Step 4: Run** `FOCUSED device_proof_decision`, then `FOCUSED lan`, then `FOCUSED emulator`. Expected: all pass; the emulator suite is still 167.
- [ ] **Step 5: Checkpoint.**

### Task 4: Pairing on the host

**Files:**
- Modify: `src/server/connection.rs` (handle `Message::AperturePairDeviceRequest` in the authorized-message path)

**Interfaces:**
- Consumes: `add` (Task 2), `primary_auth_was_password` (Task 3).
- Produces: the reply `AperturePairDeviceResponse { request_id, ok, error }`. Error strings (exact): `Pair from a password session`, `Invalid key`.
- Rules: accept only when `self.authorized` and the primary auth was `TemporaryPassword` or `PermanentPassword`; the key must be 32 bytes; the name is trimmed and capped at 64 chars, and an empty name becomes `Phone`. On success `add(...)`, one `info` log naming the phone, `ok=true`.

- [ ] **Step 1: Write the failing tests** for a pure `fn pair_decision(primary: ConnAuditPrimaryAuth, authorized: bool, key: &[u8]) -> Result<(), &'static str>`:
  - `pairing_allowed_on_password_session`
  - `pairing_refused_on_key_authenticated_session` → `Err("Pair from a password session")`
  - `pairing_refused_when_unauthorized`
  - `pairing_rejects_bad_key_length` → `Err("Invalid key")`
- [ ] **Step 2: Run** `FOCUSED pair_decision`. Expected: compile failure.
- [ ] **Step 3: Implement** `pair_decision` and the message handler.
- [ ] **Step 4: Run** `FOCUSED pair_decision`. Expected: 4 passed.
- [ ] **Step 5: Checkpoint.**

### Task 5: Phone reaches atlas without discovery, and knows it came through the LAN fast path

**Files:**
- Modify: `src/client/lan_fast_path.rs` (`start`, `private_candidates`, `remember_verified_peer`; tests)
- Modify: `src/client.rs` (`LoginConfigHandler` gets `pub via_secure_lan: bool`; set where `lan_fast_path::start`'s result is consumed)

**Interfaces:**
- Produces:
  - `fn private_candidates(peer: &str, discovered: &[DiscoveryPeer], last: Option<SocketAddr>) -> Vec<SocketAddr>`: discovery addresses first. `last` is appended only if it is a private IPv4 on port 21120 and not already present. Still capped at `MAX_CANDIDATES`.
  - After a LAN candidate succeeds, store its address in PeerConfig option `aperture-lan-last-address`.
  - `start` reports that the LAN path won (e.g. it returns the address or a bool alongside the existing tuple); the caller sets `lc.via_secure_lan = true`. Every other route leaves it `false`.

- [ ] **Step 1: Write the failing tests** (extend the existing tests in this file):
  - `stored_address_is_tried_when_discovery_is_empty`: empty discovery, `last = <atlas-ip>:21120` → `[<atlas-ip>:21120]`.
  - `stored_address_not_duplicated_and_respects_cap`
  - `public_or_wrong_port_stored_address_ignored`: `8.8.8.8:21120` or `<atlas-ip>:21118` → not included.
  - `stored_address_with_wrong_identity_is_rejected`: reuse the `controlled_peer` helper and the `wrong_host_key_is_rejected_before_application_data` pattern with the address coming from `last`.
- [ ] **Step 2: Run** `FOCUSED lan_fast_path`. Expected: the new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `FOCUSED lan_fast_path`. Expected: all pass, the existing 12 included.
- [ ] **Step 5: Checkpoint.**

### Task 6: Phone key, proof at login, rejection fallback, pairing request

**Files:**
- Create: `src/client/aperture_device_key.rs` (declared in `src/client.rs`)
- Modify: `src/client.rs` (`handle_hash` near 4656; the `LoginRequest` builder near 3894; `LoginConfigHandler` gets `pub device_proof: Option<DeviceProof>`)
- Modify: `src/client/io_loop.rs:1965-1975` (rejection handling; `AperturePairDeviceResponse` → push event)
- Modify: `src/flutter_ffi.rs` `session_set_common` (2960) and `session_get_common` (3013); `src/ui_session_interface.rs` (send the pair request)

**Interfaces:**
- Consumes: `sign_proof` (Task 1), `via_secure_lan` (Task 5), the proto messages (Task 1).
- Produces:
  - `pub fn load_or_create_key() -> sign::SecretKey` (LocalConfig `aperture-device-sign-sk`, base64; created once).
  - `pub fn is_paired(peer: &str) -> bool`, `pub fn set_paired(peer: &str, paired: bool)` (PeerConfig option `aperture-device-paired`).
  - `pub fn should_send_proof(via_secure_lan: bool, paired: bool, conn_type: ConnType) -> bool`: true only for `via_secure_lan && paired && conn_type == DEFAULT_CONN`.
  - In `handle_hash`, before the password-source chain: if `should_send_proof`, set `lc.device_proof = Some(sign_proof(...))`, send the login with an empty password, and return without any password msgbox.
  - In io_loop: on `LoginResponse` error `LOGIN_MSG_DEVICE_KEY_REJECTED` → `set_paired(peer, false)`, clear `lc.device_proof`, then call `handle_hash` again with the stored `lc.hash` on the same `peer`, which now takes the normal password path.
  - `session_set_common(key "aperture-pair-device", value "<name>")` sends `AperturePairDeviceRequest` with a new `request_id` and the public key. `session_set_common(key "aperture-forget-pairing", "")` → `set_paired(id, false)`.
  - `session_get_common(key "aperture-pairing-state")` → `"paired"` when `is_paired`; `"can-pair"` when the session logged in with a password (no proof sent) and is authorized; otherwise `"unavailable"`.
  - On `AperturePairDeviceResponse { ok: true }` → `set_paired(peer, true)`. Push event `aperture_pair_device_result` with `{ok, error}` in every case.

- [ ] **Step 1: Write the failing tests:**
  - `should_send_proof_only_on_secure_lan_paired_default_conn` (truth table: each of the three conditions false → `false`).
  - `key_is_created_once_and_reused` (two calls return the same public key; uses a temp config dir if the existing tests have that helper, otherwise test the encode/decode pair).
  - `rejection_clears_paired_flag_and_retries_with_password`: pure `fn on_device_key_rejected(paired: &mut bool, proof: &mut Option<DeviceProof>) -> RetryAction` returns `RetryAction::RerunHash`, and sets `paired = false` and `proof = None`.
- [ ] **Step 2: Run** `FOCUSED aperture_device_key`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `FOCUSED aperture_device_key`, then `FOCUSED lan_fast_path`, then `FOCUSED emulator`. Expected: all pass.
- [ ] **Step 5: Checkpoint.**

### Task 7: Flutter UI: Trust this phone and Trusted phones

**Files:**
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart` (connected-PC screen, the system or tools area)
- Modify: `flutter/lib/desktop/pages/desktop_setting_page.dart` (Security tab, next to the existing trusted-devices UI)
- Modify: `src/lang/en.rs` only if new strings are needed (follow `docs/agents/LOCALIZATION.md`; English only, plus key names)

**Interfaces:**
- Consumes: `bind.sessionGetCommon(sessionId, key: 'aperture-pairing-state', param: '')`, `bind.sessionSetCommon(sessionId, key: 'aperture-pair-device' | 'aperture-forget-pairing', value)`, the global event `aperture_pair_device_result`, `bind.mainGetCommon(key: 'aperture-trusted-phones')`, `bind.mainSetCommon(key: 'aperture-remove-trusted-phone', value: <base64>)`.
- UI copy (exact): button **Trust this phone**; after success, the text **This phone connects without a password at home**; button **Forget pairing**; settings heading **Trusted phones**; per row: the name, `Added <date>`, `Last used <date or Never>`, button **Remove**; empty state **No trusted phones**.
- Default phone name: the Android device model from the existing device-info source in the app; the builder picks the call.

- [ ] **Step 1: Inspect the running screens first** (project rule for Flutter UI): look at the current dashboard and the desktop Security tab, and place the controls in the existing style.
- [ ] **Step 2: Implement** both additions. Trust is visible only when the state is `can-pair`; Forget only when it is `paired`.
- [ ] **Step 3: Run** `flutter analyze lib/mobile/pages/target_dashboard_page.dart lib/desktop/pages/desktop_setting_page.dart` from `flutter/` with `C:\DevTools\flutter-3.24.5\bin\flutter`. Expected: no new errors or warnings compared with the same command on the unmodified file (record both).
- [ ] **Step 4: Run** the existing Flutter tests that touch these pages (`flutter test` on the affected test files, if any exist under `flutter/test/`). Expected: pass.
- [ ] **Step 5: Checkpoint.**

### Task 8: Whole-change verification and artifacts (no install)

- [ ] **Step 1:** `FOCUSED emulator`, `FOCUSED lan`, `FOCUSED aperture_`, `FOCUSED device_proof_decision`, `FOCUSED pair_decision`. Expected: 0 failed; record the counts.
- [ ] **Step 2:** `cargo build --release --lib --features flutter,hwcodec,vram`. Expected: `Finished`, with no new warnings in the changed files (compare with `target/aperture-host-fixes-20261113/checks-batch2/build.log`). Record the DLL SHA256. Do **not** overwrite `target/aperture-host-fixes-20261113/deployment/stage/`.
- [ ] **Step 3:** Build the Android native library with `tools/build_android_native_windows.ps1` and the APK using the procedure in `docs/remote/aperture-releases.md` (signing files are in `%LOCALAPPDATA%\Aperture\signing`). Verify the signature matches the installed app's certificate, as in `docs/remote/2026-10-15-aperture-lan.md`. Ask the user before this step if it needs the signing password or any prompt.
- [ ] **Step 4:** A fresh review agent (one that did not write the code) reads the full diff against the spec, with emphasis on Task 3's `on_message` branch and the Review Focus list.
- [ ] **Step 5:** Write `docs/remote/2026-11-13-phone-key-pairing.md`: what changed, the test counts, artifact hashes, and known limits (WireGuard on atlas needs a listener bind change; non-default connections still use the password).
- [ ] **Step 6:** Stop. Installing the host DLL (through the existing updater with a new pin) and the APK each need the user's go-ahead. The device checklist for afterwards: pair; reconnect at home with no prompt; remove on atlas, then the prompt appears and Trust reappears; mobile data without WireGuard shows the prompt.
