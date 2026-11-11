param(
  [ValidateSet('interactive', 'check', 'install')]
  [string]$NativeAction = 'interactive'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$fileId = '1vgiXozpivvcIFLpWzRQKuW-iX5h2qd60'
$downloadUrl = "https://drive.google.com/uc?export=download&id=$fileId"
$versionFileId = '1eJ-ML3gG4hKhgdOolwLt-sRQGy6lD1ls'
$versionUrl = "https://drive.google.com/uc?export=download&id=$versionFileId"
$installRoot = Join-Path $env:LOCALAPPDATA 'CredentialVault'
$target = Join-Path $installRoot 'Extension'
$work = Join-Path $env:TEMP ("CredentialVault-Update-" + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $installRoot 'Extension.previous'
$hostName = 'com.credentialvault.updater'
$extensionOrigin = 'chrome-extension://micgojkeebpbmhlbepmiebomdokpbcdk/'

function Write-NativeResult($Result) {
  $Result | ConvertTo-Json -Compress -Depth 4
}

function Invoke-ChromeSetup([string]$Mode = 'load') {
  $helper = Join-Path $PSScriptRoot 'chrome-setup.ps1'
  if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    Write-Host 'Chrome setup helper is missing; follow the manual steps shown above.' -ForegroundColor Yellow
    return
  }
  try {
    $completed = & $helper -ExtensionPath $target -Mode $Mode
    if (-not $completed) { Write-Host 'Chrome setup automation could not finish. Follow the manual steps shown above.' -ForegroundColor Yellow }
  } catch {
    Write-Host "Chrome setup automation could not finish: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'Follow the manual steps shown above.' -ForegroundColor Yellow
  }
}

function Install-NativeHost {
  $hostDir = Join-Path $installRoot 'NativeHost'
  $hostExe = Join-Path $hostDir 'CredentialVaultNativeHost.exe'
  $hostManifest = Join-Path $hostDir 'com.credentialvault.updater.json'
  $source = Join-Path $PSScriptRoot 'native-host\windows\CredentialVaultNativeHost.exe'
  $savedUpdater = Join-Path $installRoot 'dependency.ps1'
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Native host source is missing. Keep the native-host folder beside the installer.' }
  New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
  if ([System.IO.Path]::GetFullPath($PSCommandPath) -ne [System.IO.Path]::GetFullPath($savedUpdater)) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $savedUpdater -Force
  }
  Copy-Item -LiteralPath $source -Destination $hostExe -Force
  $manifestJson = @{ name = $hostName; description = 'Credential Vault updater'; path = $hostExe; type = 'stdio'; allowed_origins = @($extensionOrigin) } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($hostManifest, $manifestJson, [System.Text.UTF8Encoding]::new($false))
  $registryPath = "Registry::HKEY_CURRENT_USER\Software\Google\Chrome\NativeMessagingHosts\$hostName"
  New-Item -Path $registryPath -Force | Out-Null
  Set-Item -Path $registryPath -Value $hostManifest
}

$mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList @($false, 'Local\CredentialVaultUpdater')
$mutexOwned = $false
try { $mutexOwned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mutexOwned = $true }
if (-not $mutexOwned) {
  if ($NativeAction -ne 'interactive') { Write-NativeResult @{ ok = $false; status = 'busy'; error = 'Another update is already running. Try again shortly.' }; exit 0 }
  Write-Host 'Another Credential Vault update is already running. Try again shortly.' -ForegroundColor Yellow
  $mutex.Dispose()
  exit 0
}

function Read-Manifest([string]$Path, [switch]$RequireNativeUpdater) {
  $manifestPath = Join-Path $Path 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "manifest.json not found at $manifestPath" }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.manifest_version -ne 3 -or $manifest.name -ne 'Credential Vault' -or $manifest.version -notmatch '^\d+(\.\d+){1,3}$') {
    throw 'Downloaded extension manifest is invalid or is not the expected Credential Vault MV3 extension.'
  }
  if ($RequireNativeUpdater -and ($manifest.key -ne 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApTJDNECo9imX3YJA19hXHASim5ldP/tgRiLM4qHhM2Vg7X4gxzL33oWl24n9tcFegyyLajEa7oc2Pm+lTF6kIkQgx0ENifxhZGUDd2wdmp0BWir8J2Y/xAE5EdeHMABV0HT4rYOoAUdgqOjkSyPBP5GGbcKPskHHrOEmfLzdNxFjGoQQmcJgoQThaKbwMB4V4pLqFQJyN2l41YnRTzcy5GUPBzxxbHd9myrOb9MnOdnPK0nq60e4hHXssiMcwawpUEp5qvIDrIfhQwtmIhGULSQk4b+mmfXMod26y1sB65bnomDxr8UKoG8+1fL5p6OeX6LiD4rxK2ch5vFdDqx2cQIDAQAB' -or $manifest.permissions -notcontains 'nativeMessaging')) {
    throw 'This release does not contain the registered native updater. Upload the new extension build ZIP and retry.'
  }
  return $manifest
}

try {
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  try { $release = Invoke-RestMethod -Uri $versionUrl -Method Get } catch { throw 'Could not read CredentialVault-version.json from Drive. Check link sharing and internet access.' }
  if (-not $release.version -or $release.version -notmatch '^\d+(\.\d+){1,3}$') { throw 'Drive version metadata is invalid; expected JSON with a numeric version such as 1.0.10.' }
  $local = $null
  if (Test-Path -LiteralPath $target) { $local = Read-Manifest $target }
  if ($NativeAction -eq 'check') {
    if (-not $local) { Write-NativeResult @{ ok = $true; status = 'extension_missing'; currentVersion = $null; availableVersion = $release.version }; exit 0 }
    $available = [version]$release.version -gt [version]$local.version
    Write-NativeResult @{ ok = $true; status = $(if ($available) { 'update_available' } else { 'up_to_date' }); currentVersion = $local.version; availableVersion = $release.version }
    exit 0
  }
  $zip = Join-Path $work 'credential-vault.zip'
  if ($NativeAction -eq 'interactive') { Write-Host 'Downloading Credential Vault...' -ForegroundColor Cyan }
  Invoke-WebRequest -Uri $downloadUrl -OutFile $zip -UseBasicParsing
  if ((Get-Item -LiteralPath $zip).Length -lt 1000) { throw 'Drive returned a very small file. Check that the ZIP is shared for anyone with the link.' }

  $unpacked = Join-Path $work 'unpacked'
  Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
  $source = Join-Path $unpacked 'dist'
  if (-not (Test-Path -LiteralPath (Join-Path $source 'manifest.json'))) {
    if (Test-Path -LiteralPath (Join-Path $unpacked 'manifest.json')) { $source = $unpacked }
    else { throw 'ZIP layout not recognized: expected dist/manifest.json (or manifest.json at ZIP root).' }
  }
  $remote = Read-Manifest $source -RequireNativeUpdater
  if ([string]$remote.version -cne [string]$release.version) { throw "Release mismatch: Drive metadata says $($release.version), but the ZIP manifest says $($remote.version). No files were changed." }
  if ($NativeAction -eq 'interactive') {
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    Install-NativeHost
  }

  if ($NativeAction -eq 'install' -and -not $local) {
    Write-NativeResult @{ ok = $false; status = 'extension_missing'; error = 'The extension folder is missing. Run the installer and load it in Chrome again.' }
    exit 0
  }

  if ($local -and ([version]$remote.version -le [version]$local.version)) {
    if ($NativeAction -eq 'install') { Write-NativeResult @{ ok = $true; status = 'up_to_date'; currentVersion = $local.version; availableVersion = $remote.version }; exit 0 }
    Write-Host "Already current (installed $($local.version), available $($remote.version))." -ForegroundColor Green
    Write-Host "`nOpening Chrome setup for the installed folder: $target" -ForegroundColor Yellow
    Write-Host 'If automation cannot complete, manually turn on Developer mode, click Load unpacked, and select this Extension folder.'
    Invoke-ChromeSetup -Mode load
    exit 0
  }

  New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
  if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $backup }
  try { Copy-Item -LiteralPath $source -Destination $target -Recurse | Out-Null }
  catch {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $target }
    throw
  }
  if ($NativeAction -ne 'interactive') {
    Write-NativeResult @{ ok = $true; status = 'installed'; previousVersion = $local.version; currentVersion = $remote.version }
    exit 0
  }
  Write-Host "Installed Credential Vault $($remote.version) to:`n$target" -ForegroundColor Green
  if (-not $local) {
    Write-Host "`nStarting one-time Chrome setup for: $target" -ForegroundColor Yellow
    Write-Host 'If automation stops, in the selected Chrome window enable Developer mode, click Load unpacked, and select the Extension folder containing manifest.json.'
  } else {
    Write-Host "`nUpdate installed. To activate it:" -ForegroundColor Yellow
    Write-Host '1. Open Chrome and enter chrome://extensions in the address bar.'
    Write-Host '2. Find Credential Vault in the extensions list.'
    Write-Host '3. Click its Reload icon/button. If it is not visible, refresh the extensions page.'
    Write-Host '4. Return to your tabs and refresh any page where you want to use the updated extension.'
  }
  if (-not $local) { Invoke-ChromeSetup -Mode load }
  elseif ($local) { Invoke-ChromeSetup -Mode update }
} catch {
  if ($NativeAction -ne 'interactive') {
    Write-NativeResult @{ ok = $false; status = 'error'; error = $_.Exception.Message }
    exit 1
  }
  Write-Host "`nInstall/update failed: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
} finally {
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  if ($mutexOwned) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
