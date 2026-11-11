param(
  [Parameter(Mandatory = $true)][string]$ExtensionPath,
  [ValidateSet('load', 'update')][string]$Mode = 'load'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CvWindow {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);
  private static IntPtr matchingButton = IntPtr.Zero;
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
  public static IntPtr FindButton(IntPtr parent, string wantedText) {
    matchingButton = IntPtr.Zero;
    EnumChildWindows(parent, delegate(IntPtr child, IntPtr unused) {
      StringBuilder caption = new StringBuilder(256);
      StringBuilder className = new StringBuilder(128);
      GetWindowText(child, caption, caption.Capacity);
      GetClassName(child, className, className.Capacity);
      if (String.Equals(caption.ToString().Trim(), wantedText, StringComparison.OrdinalIgnoreCase) &&
          (String.Equals(className.ToString(), "Button", StringComparison.OrdinalIgnoreCase) || className.ToString().StartsWith("Button", StringComparison.OrdinalIgnoreCase))) {
        matchingButton = child;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return matchingButton;
  }
}
'@

function Get-ChromeWindows {
  $items = [System.Collections.Generic.List[object]]::new()
  $callback = [CvWindow+EnumWindowsProc]{
    param([IntPtr]$handle, [IntPtr]$unused)
    if ([CvWindow]::IsWindowVisible($handle)) {
      $pidValue = [uint32]0
      [void][CvWindow]::GetWindowThreadProcessId($handle, [ref]$pidValue)
      $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
      if ($proc -and $proc.ProcessName -eq 'chrome') {
        $title = [System.Text.StringBuilder]::new(512)
        [void][CvWindow]::GetWindowText($handle, $title, $title.Capacity)
        if ($title.Length -gt 0) { $items.Add([pscustomobject]@{ Handle = $handle; Title = $title.ToString(); Pid = $pidValue }) }
      }
    }
    return $true
  }
  [void][CvWindow]::EnumWindows($callback, [IntPtr]::Zero)
  return $items.ToArray()
}

function Find-ChromeExecutable {
  $candidates = [System.Collections.Generic.List[string]]::new()
  if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')) }
  if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')) }
  if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')) }
  $command = Get-Command chrome.exe -ErrorAction SilentlyContinue
  if ($command -and $command.Source) { $candidates.Add($command.Source) }
  foreach ($path in $candidates) {
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
  }
  foreach ($key in @(
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
  )) {
    $registryKey = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
    if ($registryKey) {
      $value = [string]$registryKey.GetValue('')
      $value = $value.Trim().Trim('"')
      if ($value -and (Test-Path -LiteralPath $value -PathType Leaf)) { return $value }
    }
  }
  return $null
}

function Get-ElementByName($Root, [string]$NamePart, [System.Windows.Automation.ControlType]$Type = $null) {
  $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($element in $all) {
    if ($element.Current.Name -like "*$NamePart*" -and (-not $Type -or $element.Current.ControlType -eq $Type)) { return $element }
  }
  return $null
}

function Invoke-Element($Element) {
  $pattern = $null
  if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); return $true }
  $pattern = $null
  if ($Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $pattern.Toggle(); return $true }
  return $false
}

function Escape-SendKeys([string]$Text) {
  $escaped = [System.Text.StringBuilder]::new()
  foreach ($character in $Text.ToCharArray()) {
    if ('+^%~(){}'.Contains([string]$character)) { [void]$escaped.Append('{').Append($character).Append('}') }
    else { [void]$escaped.Append($character) }
  }
  return $escaped.ToString()
}

function Get-WindowTitle([IntPtr]$Handle) {
  $title = [System.Text.StringBuilder]::new(512)
  [void][CvWindow]::GetWindowText($Handle, $title, $title.Capacity)
  return $title.ToString()
}

try {
  $windows = @(Get-ChromeWindows)
  if ($windows.Count -eq 0) {
    $chrome = Find-ChromeExecutable
    if (-not $chrome) { throw 'Could not locate chrome.exe. Open Google Chrome manually and rerun this installer.' }
    Write-Host 'Chrome is closed. A profile chooser will open; select the intended profile, then Alt+Tab back here and press Enter.' -ForegroundColor Yellow
    Start-Process -FilePath $chrome -ArgumentList 'chrome://profile-picker/' | Out-Null
    [void](Read-Host 'Press Enter after the intended profile window has opened')
    $windows = @(Get-ChromeWindows)
  }
  if ($windows.Count -eq 0) { throw 'Chrome did not open or has no visible window.' }

  $selected = $null
  if ($windows.Count -eq 1) { $selected = $windows[0] }
  else {
    Write-Host "`nSeveral Chrome windows are open. Choose the window for the profile where Credential Vault should be loaded:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $windows.Count; $i++) { Write-Host ("{0}. {1}" -f ($i + 1), $windows[$i].Title) }
    Write-Host 'If titles are identical or unclear, close the other Chrome windows and rerun this installer.' -ForegroundColor Yellow
    $choice = 0
    while ($choice -lt 1 -or $choice -gt $windows.Count) { [void][int]::TryParse((Read-Host 'Enter the window number'), [ref]$choice) }
    $selected = $windows[$choice - 1]
  }

  [void][CvWindow]::ShowWindow($selected.Handle, 9)
  [void][CvWindow]::SetForegroundWindow($selected.Handle)
  Start-Sleep -Milliseconds 400
  [System.Windows.Forms.SendKeys]::SendWait('^l')
  [System.Windows.Forms.SendKeys]::SendWait('chrome://extensions')
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 3

  $chromeWindow = [System.Windows.Automation.AutomationElement]::FromHandle($selected.Handle)
  if ($Mode -eq 'update') {
    Write-Host 'Chrome Extensions page opened in the selected window. Reload Credential Vault there to activate the update.' -ForegroundColor Green
    return $true
  }

  $devMode = Get-ElementByName $chromeWindow 'Developer mode' ([System.Windows.Automation.ControlType]::CheckBox)
  if (-not $devMode) { $devMode = Get-ElementByName $chromeWindow 'Developer mode' ([System.Windows.Automation.ControlType]::Button) }
  if (-not $devMode) { throw 'Could not find the Developer mode control in Chrome. The page is open for manual setup.' }
  $toggle = $null
  if ($devMode.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$toggle)) {
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $toggle.Toggle() }
  } elseif ($devMode.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox) {
    [void](Invoke-Element $devMode)
  } else { throw 'Developer mode state is not readable. The page is open for manual setup.' }
  Start-Sleep -Milliseconds 700

  $loadButton = Get-ElementByName $chromeWindow 'Load unpacked' ([System.Windows.Automation.ControlType]::Button)
  if (-not $loadButton -or -not (Invoke-Element $loadButton)) { throw 'Could not activate Load unpacked. The page is open for manual setup.' }
  Start-Sleep -Seconds 2
  [System.Windows.Forms.SendKeys]::SendWait('^l')
  [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeys $ExtensionPath))
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 2

  $pickerHandle = [CvWindow]::GetForegroundWindow()
  $picker = [System.Windows.Automation.AutomationElement]::FromHandle($pickerHandle)
  $selectButton = Get-ElementByName $picker 'Select Folder' ([System.Windows.Automation.ControlType]::Button)
  if (-not $selectButton) { $selectButton = Get-ElementByName $picker 'Select' ([System.Windows.Automation.ControlType]::Button) }
  $selectedByAutomation = $selectButton -and (Invoke-Element $selectButton)
  if (-not $selectedByAutomation) {
    # Some Windows folder pickers do not expose their buttons through UI Automation.
    $nativeButton = [CvWindow]::FindButton($pickerHandle, 'Select Folder')
    if ($nativeButton -ne [IntPtr]::Zero) {
      [void][CvWindow]::SendMessage($nativeButton, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) # BM_CLICK
    } else {
      [System.Windows.Forms.SendKeys]::SendWait('%s')
    }
  }
  Start-Sleep -Seconds 2
  if ([CvWindow]::IsWindow($pickerHandle) -and [CvWindow]::IsWindowVisible($pickerHandle) -and (Get-WindowTitle $pickerHandle) -like '*Select the extension directory*') {
    throw 'The folder picker is still open. Click Select Folder to finish loading the extension.'
  }
  Write-Host 'Chrome setup automation submitted the Extension folder. Confirm Credential Vault appears in the selected profile.' -ForegroundColor Green
  return $true
} catch {
  Write-Host "Chrome setup automation stopped: $($_.Exception.Message)" -ForegroundColor Yellow
  Write-Host "If needed, in the selected Chrome window enable Developer mode, choose Load unpacked, and select: $ExtensionPath" -ForegroundColor Yellow
  return $false
}
