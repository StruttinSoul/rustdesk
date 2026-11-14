param(
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
)
$ErrorActionPreference = 'Stop'
$helperVersion = '4.0'
$expectedHash = '84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a'
$cacheDirectory = Join-Path $env:LOCALAPPDATA "MIRPG\guest-helper\scrcpy-$helperVersion"
New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null
$cachedHelper = Join-Path $cacheDirectory "scrcpy-server-v$helperVersion"
if (!(Test-Path -LiteralPath $cachedHelper)) {
    Invoke-WebRequest "https://github.com/Genymobile/scrcpy/releases/download/v$helperVersion/scrcpy-server-v$helperVersion" -OutFile $cachedHelper
}
if ((Get-FileHash -LiteralPath $cachedHelper -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw 'Guest helper checksum does not match the pinned upstream release.'
}
$cachedLicense = Join-Path $cacheDirectory 'LICENSE'
if (!(Test-Path -LiteralPath $cachedLicense)) {
    Invoke-WebRequest "https://raw.githubusercontent.com/Genymobile/scrcpy/v$helperVersion/LICENSE" -OutFile $cachedLicense
}
$outputDirectory = Join-Path ([IO.Path]::GetFullPath($DestinationDirectory)) 'guest-helper'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
Copy-Item -LiteralPath $cachedHelper -Destination (Join-Path $outputDirectory "scrcpy-server-v$helperVersion") -Force
Copy-Item -LiteralPath $cachedLicense -Destination (Join-Path $outputDirectory 'LICENSE') -Force
@"
Android guest capture/input uses the unmodified scrcpy server v$helperVersion.
Upstream: https://github.com/Genymobile/scrcpy
License: Apache License 2.0 (included as LICENSE).
Pinned server SHA-256: $expectedHash
This helper runs through Android ADB shell and does not modify emulator binaries or images.
"@ | Set-Content -LiteralPath (Join-Path $outputDirectory 'NOTICE.txt') -Encoding UTF8
Write-Output "Verified and packaged guest helper in $outputDirectory"
