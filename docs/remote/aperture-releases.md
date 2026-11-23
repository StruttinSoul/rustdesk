# Aperture Android releases

Aperture is the Windows/Android remote-access app in this RustDesk fork. Android release metadata lives in `tools/aperture-release.json`. The first named release is **1.5.0**, Android version code **4103** (higher than test2102/4102). Download artifact: `Aperture-1.5.0-android-arm64.apk`.

## Signing and updates

The existing application ID `com.carriez.flutter_hbb.mirpgtest` is deliberately retained so existing installations retain settings and data. The internal historical suffix is not the product name. The release uses a dedicated RSA-4096 Aperture key, with Android's proof-of-rotation from the previous development signer. Android 9 and newer use the release signer; older supported Android versions retain the previous signer for compatibility. Do not uninstall or clear app data to update.

**Key replaced on 2026-11-14 (release 1.5.5, version code 4108).** The original key's DPAPI-protected password stopped decrypting after this Windows account's DPAPI keys changed on 2026-10-21, so a new RSA-4096 key (alias `aperture`, `CN=Aperture`, certificate SHA-256 `9938b4461131bbe2dd5817b9aaad00faf973facee8be8ba154f20cd3b98e85db`) was created with a fresh proof-of-rotation from the same previous development signer. Installs signed only by the development signer still update. An install of a release signed with the old key (1.5.0–1.5.4, certificate `c9d0ad94…2e24`) cannot update to 1.5.5 and must be uninstalled once. The old files are kept in `retired-20261114-password-lost/`. Besides `release-password.dpapi` (current user), the password is also stored as `release-password.machine.dpapi` (DPAPI LocalMachine scope: any process on this PC can decrypt it) so a change to the user's DPAPI keys cannot lose it again. Neither survives a Windows reinstall; keep an offline backup of the key, lineage and password.

Private keys and passwords must never be committed or uploaded. On the release workstation they live outside the checkout in `%LOCALAPPDATA%/Aperture/signing`. The password is encrypted using Windows DPAPI and can be decrypted only in the matching Windows user context. Keep a secure, recoverable backup of the key, lineage and password before retiring that Windows account or computer. Copying only the encrypted password to a different account is insufficient. The public certificate may be distributed.

## Build

1. Build and stage the Android ARM64 native libraries using the existing native build tooling (`tools/build_android_native_windows.ps1` on Windows, or `flutter/ndk_arm64.sh` on Linux). Keep the matching native source and hash. This release preserves the reviewed native library from test2102; it changes packaging/signing/version only.
2. Set `JAVA_HOME` to the supported JDK and install Android SDK build-tools 36.0.0, Flutter 3.24.5 and the existing project dependencies.
3. With the private signing files available, run:

   ```powershell
   ./tools/build_aperture_release.ps1 -NativeLibrarySha256 <reviewed-librustdesk.so-SHA256>
   ```

   Optional parameters override the signing directory, legacy keystore, Android SDK directory and output directory. Signing files are `aperture-release.p12` (alias `aperture`), `release-password.dpapi`, `aperture-signing-lineage.bin` and `aperture-release-certificate.pem`. The old keystore is needed to sign for legacy Android versions.

The wrapper builds an unsigned non-debuggable Aperture APK, aligns native libraries for 16 KiB pages, signs with the release key and upgrade lineage, verifies signatures and metadata, and produces the named APK, `SHA256SUMS.txt`, and public certificate. It refuses to overwrite an existing release APK. Tests and device deployment are separate, explicit steps; the wrapper does not run tests, install, or launch the app. Upstream RustDesk and existing test build modes are retained.

For future releases, increment the semantic version and strictly increase `versionCode`. Do not rename an old APK and present it as a new build. Publish matching source and the APK/checksum together.

## Android installation warnings

A valid release signature establishes app identity and update continuity. It is not a Google approval or a guarantee against Play Protect warnings. GitHub downloads are sideloaded apps. For an unknown-app scan prompt, allow Google to scan the APK. An appeal does not remove that informational scan prompt. If Google instead classifies the app as harmful or blocks it in error, use the official developer review/appeal process. Do not disable Play Protect, strip remote-access permissions blindly, or claim GitHub hosting eliminates these warnings.

References: [Android signing tools](https://developer.android.com/tools/apksigner), [Google Play Protect developer guidance](https://developers.google.com/android/play-protect/warning-dev-guidance).

## Acceptance limits

This release packages the existing Windows/Android dashboard, emulator controls and LAN connection improvements. It is an Android ARM64 release, not a new Windows installer. The latest emulator decoder-burst correction has native regression evidence from the preceding development session, but end-to-end phone smoothness has not been accepted. No phone or performance tests were run for release publication, as requested by the user. The Play Protect unknown-developer warning requires a separate Google-side determination and is not claimed fixed.
