param(
    [Parameter(Mandatory = $true)][string]$NativeLibrarySha256,
    [string]$SigningDirectory = (Join-Path $env:LOCALAPPDATA 'Aperture\signing'),
    [string]$LegacyKeystore = (Join-Path $env:USERPROFILE '.android\debug.keystore'),
    [string]$AndroidSdkDirectory = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$version = Get-Content (Join-Path $PSScriptRoot 'aperture-release.json') -Raw | ConvertFrom-Json
if ($version.version -notmatch '^\d+\.\d+\.\d+$' -or $version.versionCode -lt 4103) { throw 'Invalid release version.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo "target\aperture-release-$($version.version)" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$apk = Join-Path $OutputDirectory "Aperture-$($version.version)-android-arm64.apk"
if (Test-Path -LiteralPath $apk) { throw "Release APK already exists: $apk" }
$sdkTools = Join-Path $AndroidSdkDirectory 'build-tools\36.0.0'
$keystore = Join-Path $SigningDirectory 'aperture-release.p12'
$lineage = Join-Path $SigningDirectory 'aperture-signing-lineage.bin'
$passwordFile = Join-Path $SigningDirectory 'release-password.dpapi'
$certificate = Join-Path $SigningDirectory 'aperture-release-certificate.pem'
foreach ($file in @($keystore, $lineage, $passwordFile, $certificate, $LegacyKeystore)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Required signing file missing: $file" }
}
$jni = Join-Path $repo 'flutter\android\app\src\main\jniLibs\arm64-v8a\librustdesk.so'
if ((Get-FileHash -LiteralPath $jni -Algorithm SHA256).Hash -ne $NativeLibrarySha256) {
    throw 'JNI does not match the reviewed native library hash. Build/stage the native library first.'
}
# The password remains encrypted at rest with Windows DPAPI; never log it.
$securePassword = (Get-Content -LiteralPath $passwordFile -Raw).Trim() | ConvertTo-SecureString
$env:APERTURE_SIGNING_PASSWORD = [Net.NetworkCredential]::new('', $securePassword).Password
$properties = Join-Path $repo 'flutter\android\local.properties'
$propertiesBefore = [IO.File]::ReadAllBytes($properties)
try {
    Push-Location (Join-Path $repo 'flutter\android')
    try {
        & ./gradlew.bat ':app:assembleRelease' '-PapertureRelease=true' '-Ptarget-platform=android-arm64' '-Ptarget=lib/main.dart' '--no-daemon' '--stacktrace' '-Dorg.gradle.jvmargs=-Xmx4g' '--max-workers=2' *> (Join-Path $OutputDirectory 'build.log')
        if ($LASTEXITCODE -ne 0) { throw "APK build failed; see $OutputDirectory/build.log" }
    } finally { Pop-Location }
    $unsigned = Join-Path $repo 'flutter\build\app\outputs\apk\release\app-release-unsigned.apk'
    if (-not (Test-Path -LiteralPath $unsigned)) { throw 'Unsigned release APK missing.' }
    $aligned = Join-Path $OutputDirectory 'app-aligned-unsigned.apk'
    & "$sdkTools/zipalign.exe" -P 16 -f 4 $unsigned $aligned
    if ($LASTEXITCODE -ne 0) { throw 'APK alignment failed.' }
    & "$sdkTools/apksigner.bat" sign --ks $LegacyKeystore --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --next-signer --ks $keystore --ks-key-alias aperture --ks-pass env:APERTURE_SIGNING_PASSWORD --lineage $lineage --rotation-min-sdk-version 28 --debuggable-apk-permitted false --v4-signing-enabled false --out $apk $aligned
    if ($LASTEXITCODE -ne 0) { throw 'Release signing failed.' }
    & "$sdkTools/apksigner.bat" verify --verbose --print-certs $apk *> (Join-Path $OutputDirectory 'signature.txt')
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    $modernCert = & "$sdkTools/apksigner.bat" verify --min-sdk-version 28 --max-sdk-version 36 --print-certs $apk 2>$null
    if ($LASTEXITCODE -ne 0 -or ($modernCert -join "`n") -notmatch [regex]::Escape($version.signingCertificateSha256)) {
        throw 'APK does not use the pinned Aperture release certificate on modern Android.'
    }
    & "$sdkTools/zipalign.exe" -c -P 16 4 $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK 16 KiB alignment verification failed.' }
    $badging = & "$sdkTools/aapt.exe" dump badging $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK metadata inspection failed.' }
    $package = $badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1
    if ($package -notlike "*name='$($version.package)'*" -or $package -notlike "*versionCode='$($version.versionCode)'*" -or $package -notlike "*versionName='$($version.version)'*") { throw 'Unexpected release package/version.' }
    if ($badging -notcontains "application-label:'Aperture'" -or $badging -contains 'application-debuggable') { throw 'Release branding/debuggability is incorrect.' }
    if ($badging -notcontains "targetSdkVersion:'36'") { throw 'Unexpected target SDK.' }
    $package | Set-Content (Join-Path $OutputDirectory 'package.txt') -Encoding UTF8
    Copy-Item -LiteralPath $certificate -Destination (Join-Path $OutputDirectory 'Aperture-signing-certificate.pem')
    $hash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($apk))" | Set-Content (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii
    Write-Output "Release APK: $apk"
    Write-Output "SHA256: $hash"
    Write-Output $package
} finally {
    Remove-Item Env:APERTURE_SIGNING_PASSWORD -ErrorAction SilentlyContinue
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($properties)) -ne [Convert]::ToBase64String($propertiesBefore)) {
        [IO.File]::WriteAllBytes($properties, $propertiesBefore)
        throw 'Gradle changed local.properties; original bytes restored. Inspect before publishing.'
    }
}
