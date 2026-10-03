param(
    [Parameter(Mandatory = $true)][string]$NdkDirectory,
    [Parameter(Mandatory = $true)][string]$VcpkgDirectory,
    [Parameter(Mandatory = $true)][string]$SodiumLibraryDirectory,
    [Parameter(Mandatory = $true)][string]$ClangDirectory,
    [Parameter(Mandatory = $true)][string]$HwcodecCheckout,
    [Parameter(Mandatory = $true)][string]$SodiumCheckout,
    [string]$OpenSslDirectory,
    [string]$TargetDirectory = (Join-Path $env:LOCALAPPDATA 'MIRPG\android-target'),
    [string]$LogPath = (Join-Path $env:TEMP 'mirpg-android-native.log')
)
$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $HwcodecCheckout 'build.rs'
$originalBytes = [IO.File]::ReadAllBytes($buildScript)
$original = [Text.Encoding]::UTF8.GetString($originalBytes)
$commonStart = $original.IndexOf('fn build_common(')
$commonEnd = $original.IndexOf('#[derive(Debug)]', $commonStart)
if ($commonStart -lt 0 -or $commonEnd -lt 0) {
    throw 'Unrecognized hwcodec build script; refusing to change it.'
}
$common = $original.Substring($commonStart, $commonEnd - $commonStart)
if ([regex]::Matches($common, '#\[cfg\(windows\)\]').Count -ne 2) {
    throw 'Unrecognized hwcodec Windows blocks; refusing to change them.'
}
$corrected = $common.Replace("#[cfg(windows)]", "#[cfg(windows)]`n    if target_os == `"windows`"")
$patched = $original.Substring(0, $commonStart) + $corrected + $original.Substring($commonEnd)
$backup = "$buildScript.mirpg-original"
if (Test-Path -LiteralPath $backup) {
    throw "A previous build backup exists at $backup; restore it before continuing."
}
$sodiumBuildScript = Join-Path $SodiumCheckout 'build.rs'
$sodiumBytes = [IO.File]::ReadAllBytes($sodiumBuildScript)
$sodiumOriginal = [Text.Encoding]::UTF8.GetString($sodiumBytes)
if ([regex]::Matches($sodiumOriginal, 'fn main\(\) \{').Count -ne 1) {
    throw 'Unrecognized libsodium build script; refusing to change it.'
}
$sodiumPatched = $sodiumOriginal.Replace('fn main() {', @'
fn main() {
    println!("cargo:rerun-if-env-changed=MIRPG_ANDROID_SODIUM_LIB_DIR");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        if let Ok(directory) = env::var("MIRPG_ANDROID_SODIUM_LIB_DIR") {
            env::set_var("SODIUM_LIB_DIR", directory);
        }
    }
'@)
$sodiumBackup = "$sodiumBuildScript.mirpg-original"
if (Test-Path -LiteralPath $sodiumBackup) {
    throw "A previous build backup exists at $sodiumBackup; restore it before continuing."
}
$ndkBin = (Join-Path $NdkDirectory 'toolchains\llvm\prebuilt\windows-x86_64\bin').Replace('\', '/')
$sysroot = (Join-Path $NdkDirectory 'toolchains\llvm\prebuilt\windows-x86_64\sysroot').Replace('\', '/')
$clangVersions = Get-ChildItem -LiteralPath (Join-Path $ClangDirectory 'lib\clang') -Directory
$resourceDirectory = ($clangVersions | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).FullName.Replace('\', '/')
if (!(Test-Path -LiteralPath "$resourceDirectory/include/stddef.h")) {
    throw 'Clang resource headers are missing.'
}
if (!(Test-Path -LiteralPath (Join-Path $SodiumLibraryDirectory 'libsodium.a'))) {
    throw 'Build the arm64-Android libsodium static archive first.'
}
Copy-Item -LiteralPath (Join-Path $SodiumLibraryDirectory 'libsodium.a') -Destination (Join-Path $SodiumLibraryDirectory 'liblibsodium.a') -Force
[IO.File]::WriteAllBytes($backup, $originalBytes)
try {
    # The dependency's two Windows blocks use the build host instead of the target.
    # Restore its exact bytes even if the cross build fails; no dependency pin changes.
    [IO.File]::WriteAllText($buildScript, $patched, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes($sodiumBackup, $sodiumBytes)
    [IO.File]::WriteAllText($sodiumBuildScript, $sodiumPatched, [Text.UTF8Encoding]::new($false))
    $env:ANDROID_NDK_HOME = $NdkDirectory
    $env:ANDROID_NDK_ROOT = $NdkDirectory
    $env:CC_aarch64_linux_android = "$ndkBin/clang.exe"
    $env:CXX_aarch64_linux_android = "$ndkBin/clang++.exe"
    $env:CFLAGS_aarch64_linux_android = '--target=aarch64-linux-android21'
    $env:CXXFLAGS_aarch64_linux_android = '--target=aarch64-linux-android21'
    $env:AR_aarch64_linux_android = "$ndkBin/llvm-ar.exe"
    $env:RANLIB_aarch64_linux_android = "$ndkBin/llvm-ranlib.exe"
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "$ndkBin/aarch64-linux-android21-clang.cmd"
    $env:BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "--target=aarch64-linux-android21 --sysroot=$sysroot -resource-dir=$resourceDirectory"
    $env:VCPKG_ROOT = $VcpkgDirectory
    $env:VCPKG_DEFAULT_TRIPLET = 'arm64-android'
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    $env:LIBCLANG_PATH = Join-Path $ClangDirectory 'bin'
    Remove-Item Env:SODIUM_LIB_DIR -ErrorAction SilentlyContinue
    $env:MIRPG_ANDROID_SODIUM_LIB_DIR = $SodiumLibraryDirectory
    $env:CARGO_TARGET_DIR = $TargetDirectory
    $env:CARGO_BUILD_JOBS = '2'
    $env:CARGO_PROFILE_RELEASE_RPATH = 'false'
    $env:MAKEFLAGS = '-j8'
    if ($OpenSslDirectory) {
        $env:OPENSSL_NO_VENDOR = '1'
        $env:OPENSSL_LIB_DIR = Join-Path $OpenSslDirectory 'lib'
        $env:OPENSSL_INCLUDE_DIR = Join-Path $OpenSslDirectory 'include'
        $env:OPENSSL_STATIC = '1'
    }
    $msysRoot = Get-ChildItem -LiteralPath (Join-Path $VcpkgDirectory 'downloads\tools\msys2') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'usr\bin\make.exe') } |
        Select-Object -First 1
    if (!$msysRoot) { throw 'The vcpkg MSYS make runtime is missing.' }
    $env:Path = (Join-Path $msysRoot.FullName 'usr\bin') + ';' + $env:Path
    Push-Location $projectDirectory
    try {
        $resolvedTargetDirectory = [IO.Path]::GetFullPath($TargetDirectory)
        New-Item -ItemType Directory -Path $resolvedTargetDirectory -Force | Out-Null
        if ((Get-Item -LiteralPath $resolvedTargetDirectory).LinkType) {
            throw 'Refusing package-cache cleanup through a directory link.'
        }
        # Cargo treats registry/git sources as immutable. Recompile these two build
        # scripts in this private cache so the temporary target fixes take effect.
        cargo clean --target-dir $resolvedTargetDirectory --release --package hwcodec --package libsodium-sys *> $LogPath
        if ($LASTEXITCODE -ne 0) { throw "Native package-cache cleanup failed; see $LogPath" }
        cargo build --target aarch64-linux-android --locked --release --lib --features flutter,hwcodec --keep-going *>> $LogPath
        if ($LASTEXITCODE -ne 0) { throw "Android native build failed; see $LogPath" }
        $jniDirectory = Join-Path $projectDirectory 'flutter\android\app\src\main\jniLibs\arm64-v8a'
        New-Item -ItemType Directory -Force -Path $jniDirectory | Out-Null
        Copy-Item -LiteralPath (Join-Path $TargetDirectory 'aarch64-linux-android\release\liblibrustdesk.so') -Destination (Join-Path $jniDirectory 'librustdesk.so') -Force
        Copy-Item -LiteralPath "$sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" -Destination $jniDirectory -Force
        Write-Output "Built and copied arm64 native libraries to $jniDirectory"
    } finally {
        Pop-Location
    }
} finally {
    [IO.File]::WriteAllBytes($buildScript, $originalBytes)
    Remove-Item -LiteralPath $backup
    if (Test-Path -LiteralPath $sodiumBackup) {
        [IO.File]::WriteAllBytes($sodiumBuildScript, $sodiumBytes)
        Remove-Item -LiteralPath $sodiumBackup
    }
}
