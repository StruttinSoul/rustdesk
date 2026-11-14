param(
    [ValidateSet('Inspect', 'Enable', 'Disable')][string]$Mode = 'Inspect',
    [string[]]$InstanceId = @(),
    [string]$PackageDirectory = (Join-Path $PSScriptRoot 'host')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (![Environment]::Is64BitProcess) { throw 'Run this tool in 64-bit Windows PowerShell.' }
$bootRoot = Join-Path $env:ProgramData 'MIRPG-EmulatorBoot'
$registryPath = 'HKLM:\SOFTWARE\MIRPG\EmulatorBoot'
$receiptPath = Join-Path $bootRoot 'setup-state.json'
$installRoot = Join-Path $env:ProgramFiles 'RustDesk'

function Assert-NoReparse([string]$Path) {
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing a linked path: $Path"
    }
}
function Assert-ProtectedPath([string]$Path) {
    Assert-NoReparse $Path
    $acl = Get-Acl -LiteralPath $Path
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) {
        throw "Privileged startup requires an administrator-owned path: $Path"
    }
    $writeMask = [int64][Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    $writeMask = $writeMask -bor 0x40000000 -bor 0x10000000
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -eq 'Allow' -and $trusted -notcontains $sid -and
            ([int64]$rule.FileSystemRights -band $writeMask)) { throw "Privileged startup refuses a user-writable path: $Path" }
    }
}
function Protect-Directory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Assert-NoReparse $Path
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    foreach ($entry in @(@('S-1-5-18','FullControl'), @('S-1-5-32-544','FullControl'), @('S-1-5-11','ReadAndExecute'))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]$entry[0], $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Protect-Registry {
    New-Item -Path $registryPath -Force | Out-Null
    $acl = New-Object Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    foreach ($entry in @(@('S-1-5-18','FullControl'), @('S-1-5-32-544','FullControl'), @('S-1-5-11','ReadKey'))) {
        $rule = New-Object Security.AccessControl.RegistryAccessRule(
            [Security.Principal.SecurityIdentifier]$entry[0], $entry[1], 'ContainerInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $registryPath -AclObject $acl
}
function Get-Selection {
    if (!(Test-Path $registryPath)) { return $null }
    return (Get-Item -Path $registryPath).GetValue('Selection', $null)
}
function Restore-Selection($Previous) {
    if ($null -eq $Previous) {
        if (Test-Path $registryPath) { Remove-ItemProperty -Path $registryPath -Name Selection -ErrorAction SilentlyContinue }
    } else { Set-ItemProperty -Path $registryPath -Name Selection -Value ([string]$Previous) -Type String }
}
function Verify-Package([string]$Directory, [switch]$Installed) {
    Assert-NoReparse $Directory
    $manifest = Get-Content -LiteralPath (Join-Path $Directory 'HOST-SHA256.json') -Raw | ConvertFrom-Json
    $properties = @($manifest.PSObject.Properties)
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Where-Object Name -ne 'HOST-SHA256.json')
    if (!$Installed -and $files.Count -ne $properties.Count) { throw 'Host package file count differs from its manifest.' }
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Recurse -Force) { Assert-NoReparse $item.FullName }
    foreach ($entry in $properties) {
        $file = [IO.Path]::GetFullPath((Join-Path $Directory $entry.Name))
        if (!$file.StartsWith(([IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Unsafe package manifest path.'
        }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Value) { throw "Host checksum mismatch: $($entry.Name)" }
    }
    return $manifest
}

$service = Get-CimInstance Win32_Service -Filter "Name='RustDesk'"
if ($Mode -eq 'Inspect') {
    [pscustomobject]@{ Mode = 'Experimental pre-login probe'; EnabledSelection = Get-Selection
        Service = $service | Select-Object Name, State, StartMode, StartName, PathName
        Report = Join-Path $bootRoot 'last-run.json' } | ConvertTo-Json -Depth 5
    if (Test-Path -LiteralPath (Join-Path $bootRoot 'last-run.json')) {
        Get-Content -LiteralPath (Join-Path $bootRoot 'last-run.json') -Raw
    }
    return
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Windows administrator access is required. Use the packaged Enable or Disable shortcut and accept Windows UAC.'
}
if ($Mode -eq 'Disable') {
    if (!(Test-Path -LiteralPath $receiptPath)) { throw 'No setup record exists; no settings were changed.' }
    Assert-ProtectedPath $bootRoot
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $current = Get-Selection
    if ($current -eq $receipt.PreviousSelection) { Write-Output 'Already disabled/restored.'; return }
    if ($current -ne $receipt.AppliedSelection) { throw 'Startup selection changed outside this tool; refusing to overwrite it.' }
    Restore-Selection $receipt.PreviousSelection
    Write-Output 'Previous startup selection restored. Running emulators and the RustDesk service were left alone.'
    return
}

$package = [IO.Path]::GetFullPath($PackageDirectory)
$manifest = Verify-Package $package
$blueStacks = Get-ItemProperty 'HKLM:\SOFTWARE\BlueStacks_nxt'
$player = Join-Path $blueStacks.InstallDir 'HD-Player.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $player
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(Now\.gg|Bluestack)') {
    throw 'The detected BlueStacks player does not have a valid official signature.'
}
$programFilesPrefix = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\') + '\'
if (![IO.Path]::GetFullPath($player).StartsWith($programFilesPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'This privileged probe requires BlueStacks in a protected Program Files installation.'
}
Assert-ProtectedPath $blueStacks.InstallDir
Assert-ProtectedPath $player
$configPath = Join-Path $blueStacks.UserDefinedDir 'bluestacks.conf'
$config = Get-Content -LiteralPath $configPath -Raw
$knownInstances = @([regex]::Matches($config, '(?m)^bst\.instance\.([A-Za-z0-9_]+)\.display_name=') | ForEach-Object { $_.Groups[1].Value })
if (!$InstanceId.Count) {
    $selectionFile = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'boot-selection.json') -Raw | ConvertFrom-Json
    $InstanceId = @($selectionFile.instances)
}
if (!$InstanceId.Count -or $InstanceId.Count -gt 8 -or @($InstanceId | Select-Object -Unique).Count -ne $InstanceId.Count) {
    throw 'Select one to eight distinct BlueStacks instances.'
}
foreach ($id in $InstanceId) {
    if ($id -notmatch '^[A-Za-z0-9_]{1,128}$' -or $knownInstances -notcontains $id) { throw "Invalid or undiscovered instance: $id" }
}
$selection = [ordered]@{ version = 1; enabled = $true; instances = @($InstanceId) } | ConvertTo-Json -Compress
$expectedServicePath = '"' + (Join-Path $installRoot 'rustdesk.exe') + '" --service'
if ($service) {
    if ($service.PathName -ne $expectedServicePath -or $service.StartName -ne 'LocalSystem' -or $service.StartMode -notin @('Auto', 'Disabled')) {
        throw 'An existing RustDesk service has a different installation or account; refusing to replace it.'
    }
    if (!(Test-Path -LiteralPath $receiptPath) -or
        (Get-FileHash -LiteralPath (Join-Path $installRoot 'librustdesk.dll')).Hash -ne $manifest.'librustdesk.dll') {
        throw 'Existing service is not this probe build; refusing to overwrite it.'
    }
} elseif (Test-Path -LiteralPath $installRoot) {
    throw 'A RustDesk installation directory already exists without the expected service. Review it before installing this probe.'
}
if (!$service) {
    foreach ($uninstallKey in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $existing = Get-ChildItem -Path $uninstallKey | Get-ItemProperty | Where-Object {
            $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -eq 'RustDesk'
        }
        if ($existing) { throw 'An existing registered RustDesk installation must be reviewed before installing this probe.' }
    }
}
if ((Test-Path -LiteralPath $bootRoot) -and !(Test-Path -LiteralPath $receiptPath)) {
    throw 'An unrecognized boot-probe directory already exists; refusing to overwrite it.'
}
if (Test-Path -LiteralPath $bootRoot) { Assert-ProtectedPath $bootRoot }
$previous = Get-Selection
if ($null -ne $previous -and !(Test-Path -LiteralPath $receiptPath)) { throw 'An unowned startup selection exists; refusing to replace it.' }
if ($service -and $service.State -eq 'Running' -and $previous -eq $selection) {
    $null = Verify-Package $installRoot -Installed
    Write-Output 'Already enabled with the selected instances and matching host. No restart was needed.'
    return
}
Protect-Directory $bootRoot
Protect-Registry
$receipt = if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } else {
    [pscustomobject]@{ PreviousSelection = $previous; AppliedSelection = $selection; BlueStacksVersion = $blueStacks.Version }
}
if ($null -ne $previous -and $previous -ne $receipt.AppliedSelection -and $previous -ne $receipt.PreviousSelection) {
    throw 'Startup settings were changed manually; refusing to overwrite them.'
}
$receipt.AppliedSelection = $selection
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
$previousServiceMode = if ($service) { $service.StartMode } else { $null }
try {
    if (!$service) {
        $stage = Join-Path $bootRoot 'installer-host'
        Protect-Directory $stage
        Copy-Item -Path (Join-Path $package '*') -Destination $stage -Recurse -Force
        $null = Verify-Package $stage
        Set-ItemProperty -Path $registryPath -Name Selection -Value $selection -Type String
        $installer = Start-Process -FilePath (Join-Path $stage 'rustdesk.exe') -ArgumentList '--silent-install','printer=0' -WindowStyle Hidden -PassThru
        if (!$installer.WaitForExit(120000)) { throw 'Installer did not finish within two minutes; check its status before retrying.' }
    } else {
        Set-ItemProperty -Path $registryPath -Name Selection -Value $selection -Type String
        if ($previousServiceMode -eq 'Disabled') { Set-Service -Name RustDesk -StartupType Automatic }
        Restart-Service -Name RustDesk
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $service = Get-CimInstance Win32_Service -Filter "Name='RustDesk'"
        if ($service -and $service.State -eq 'Running') { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$service -or $service.State -ne 'Running' -or $service.PathName -ne $expectedServicePath) { throw 'Expected RustDesk service is not running.' }
    $null = Verify-Package $installRoot -Installed
    Write-Output "Enabled experimental startup for: $($InstanceId -join ', '). Official BlueStacks $($blueStacks.Version)."
    Write-Output 'Cold-boot compatibility is unverified. At your next planned reboot, connect from the phone before anyone signs in.'
    Write-Output "Report: $(Join-Path $bootRoot 'last-run.json'). Disable restores only this tool's startup selection."
} catch {
    Restore-Selection $previous
    if ($previousServiceMode -eq 'Disabled') { Set-Service -Name RustDesk -StartupType Disabled }
    throw
}
