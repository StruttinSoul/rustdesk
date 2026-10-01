# Android Emulator Remote — Checkpoint A Baseline

Date: 2026-10-01

## Repository

- Upstream repository: `https://github.com/rustdesk/rustdesk`
- Fork repository: `https://github.com/StruttinSoul/rustdesk`
- Default branch: `master`
- Upstream commit: `fada664df7a294d1d1a9ca3e7cd3637069122f17`
- Fork baseline commit: `fada664df7a294d1d1a9ca3e7cd3637069122f17`
- Feature branch: `feature/android-emulator-remote`
- Submodule `libs/hbb_common`: `229b904508364c8997aad0fb5af57effac859f60`

`origin` points to the fork and `upstream` points to the official RustDesk repository.

## Toolchain

- Rust: `rustc 1.75.0 (82e1608df 2023-12-21)`
- Cargo: `cargo 1.75.0 (1d8b05cdd 2023-11-20)`
- Windows x64 build Flutter: `3.24.5`
- Windows x64 build Dart: `3.5.4`
- Bridge-generation Flutter: `3.22.3`
- Bridge-generation Dart: `3.4.4`
- `flutter_rust_bridge_codegen`: `1.80.1`
- `cargo-expand`: `1.0.95`
- LLVM/Clang: `15.0.6`
- Visual Studio: Community 2022, C++ toolchain available
- Windows kernel build: `22631` (Windows 11 23H2 generation)
- Android SDK platforms installed: 34, 35, 36, 37.0
- Android NDK: `28.2.13676358` (r28c)
- Android platform-tools / ADB: available
- Android CI JDK: 17
- Android Gradle: `8.11.1`
- Android Gradle Plugin: `8.10.1`
- Android Kotlin plugin: `2.1.21`
- Android compile/target SDK: 36
- Android min SDK: 22
- `cargo-ndk`: `3.1.2`
- vcpkg: commit `9e593bb18ea69cc5095e012465dcd675a822ed0d`
- vcpkg triplet: `x64-windows-static`

The build versions above follow the current RustDesk CI rather than the host's newer default Rust and Flutter installations.

## Generated bridge

RustDesk does not commit its generated Flutter/Rust bridge outputs. The baseline bridge was generated using the same versions and flow as `.github/workflows/bridge.yml`, including:

- `src/bridge_generated.rs`
- `src/bridge_generated.io.rs`
- `flutter/lib/generated_bridge.dart`
- `flutter/lib/generated_bridge.freezed.dart`
- platform bridge headers

These outputs remain gitignored.

## Baseline verification

### Flutter

`flutter test --no-pub --timeout 60s` completed successfully with:

- 132 tests passed
- 0 test failures

The first attempt failed before bridge generation because the generated bridge files were absent. After reproducing the repository's bridge-generation workflow with Flutter 3.22.3 and LLVM 15, the suite passed.

### Native Windows dependencies

The manifest-driven vcpkg install is intentionally used instead of the shorter dependency list in the README because the current Flutter Windows CI builds additional codec dependencies from `vcpkg.json`.

The first local manifest install used `--triplet x64-windows-static` without also setting the host triplet. Because the Windows FFmpeg entry in `vcpkg.json` is a host dependency, that put FFmpeg under `x64-windows` while `hwcodec` searched the static tree. The CI workflow explicitly sets `VCPKG_DEFAULT_HOST_TRIPLET` to the matrix triplet. Re-running the install with `VCPKG_DEFAULT_HOST_TRIPLET=x64-windows-static` installed FFmpeg and the remaining codec dependencies into the expected static tree. The install completed successfully. The existing upstream Opus CRT-linkage and libyuv/MSVC performance warnings remain non-fatal.

### Rust library tests

`cargo test --locked --lib` completed successfully with:

- 341 tests passed
- 0 test failures
- 3 tests ignored

The build emitted existing upstream warnings, including redundant imports and lints that Rust 1.75 does not recognize. No baseline test failed.

Known pre-existing baseline failures: none observed in the verified Rust or Flutter test suites or the CI-style Windows release-library build.

### Windows release library build

With `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\LLVM-15.0.6\bin`, the CI-style native library command completed successfully:

`cargo build --locked --features flutter,hwcodec,vram --lib --release`

The successful build followed the corrected static host-triplet install above and finished with only existing compiler warnings.

### Android client build baseline

RustDesk's checked-in Android native build scripts use the Linux NDK toolchain (`prebuilt/linux-x86_64`), and this Windows host has no general-purpose Linux WSL distribution installed. Rather than invent a divergent Android native build path, Checkpoint A uses the official RustDesk CI result for the exact baseline commit as the Android client build baseline.

Official upstream **Full Flutter CI** run `36739752618` built commit `fada664df7a294d1d1a9ca3e7cd3637069122f17` successfully. Within that exact-commit run, all three Android APK matrix jobs completed successfully:

- `aarch64-linux-android` — success
- `armv7-linux-androideabi` — success
- `x86_64-linux-android` — success

The same run's Flutter/Rust bridge-generation job for Flutter 3.22.3 also completed successfully. The universal APK aggregation job was skipped by workflow conditions; it is not an architecture-specific compile gate.

Run: `https://github.com/rustdesk/rustdesk/actions/runs/36739752618`

## Known baseline observations

- No emulator production code has been added.
- LDPlayer 9.2.0.1 is installed locally at `D:\LDPlayer\LDPlayer9`.
- Three LDPlayer instances are configured; none were running during the audit.
- BlueStacks 5 is not currently installed; only a residual per-user registry key was found.
- The running `LDRemoteSvc` service belongs to OSLink and must not be treated as proof that an LDPlayer guest is running.
- LDPlayer ships a local ADB server bound to loopback. No emulator ADB endpoint was exposed publicly during the audit.

## CI/build notes

- `.github/workflows/flutter-build.yml` is the authoritative Windows/Android build reference.
- `.github/workflows/bridge.yml` is the authoritative FFI bridge-generation reference.
- A normal Windows x64 CI-style build expands to a Rust library build with `flutter,hwcodec,vram` followed by `flutter build windows --release`.
- Checkpoint A verified the Rust release library portion directly. A packaged Windows Flutter application build was not required to establish the baseline for the components being modified.
- Current Android Rust/JNI scripts are Linux/CI-oriented and reference the NDK Linux toolchain. The exact baseline commit's official Android CI matrix is therefore recorded above as the client-side build baseline; future Android-native changes must be verified through the same CI-equivalent path.
