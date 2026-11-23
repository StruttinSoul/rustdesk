# Rebuild the self-contained Studio V4 reviewer ZIP, preserving its relative image links.
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipPath = Join-Path $base 'MIRPG-Studio-V4-Package.zip'
$items = @(
  'MIRPG-Studio-V4.fig'
  'MIRPG-Studio-V4-dark.fig'
  'MIRPG-Studio-V4-Preview.html'
  'build-studio-v4.js'
  'build-studio-v4-dark.js'
  'qa/MIRPG-STUDIO-V4-REVIEW.md'
  'qa/MIRPG-Studio-V4-lint.json'
  'qa/MIRPG-Studio-V4-dark-lint.json'
  'exports/MIRPG-Studio-V4-all.png'
  'exports/MIRPG-Studio-V4-all-dark.png'
  'exports/MIRPG-Studio-V4-home.png'
  'exports/MIRPG-Studio-V4-home-dark.png'
  'exports/MIRPG-Studio-V4-screens.png'
  'exports/MIRPG-Studio-V4-screens-dark.png'
  'exports/MIRPG-Studio-V4-android.png'
  'exports/MIRPG-Studio-V4-android-dark.png'
  'exports/MIRPG-Studio-V4-windows.png'
  'exports/MIRPG-Studio-V4-windows-dark.png'
  'exports/MIRPG-Studio-V4-codex.png'
  'exports/MIRPG-Studio-V4-codex-dark.png'
  'exports/MIRPG-Studio-V4-recovery.png'
  'exports/MIRPG-Studio-V4-recovery-dark.png'
)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($item in $items) {
  $path = Join-Path $base ($item -replace '/', '\')
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required file: $item"
  }
}
if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($item in $items) {
    $source = Join-Path $base ($item -replace '/', '\')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $archive, $source, $item, [System.IO.Compression.CompressionLevel]::Optimal
    ) | Out-Null
  }
} finally {
  $archive.Dispose()
}
$testArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  if ($testArchive.Entries.Count -ne $items.Count) {
    throw "Expected $($items.Count) items; got $($testArchive.Entries.Count)"
  }
  "Package verified: $($testArchive.Entries.Count) entries"
} finally {
  $testArchive.Dispose()
}
Get-Item $zipPath | Select-Object FullName,Length
