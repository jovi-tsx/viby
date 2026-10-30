# M1 native smoke: tray surface, options window, close semantics.
# REMOVED 2026-08-15 by explicit user decision — do NOT re-add or re-run:
# - the Narrator section (announcement/focus-order capture): this environment
#   has no interactive Narrator session;
# - the 200% scaling check (former -ExpectedDpi 192 parameter): this
#   environment has no 200% display.
# The M1 DPI/Narrator evidence gap was user-accepted 2026-08-14 (DELIVERY_LOG
# 18:10 UTC). Narrator/scaling proof stays out of every smoke in this repo.
# Run from WSL: powershell.exe -ExecutionPolicy Bypass -File scripts\smoke-m1.ps1
# Evidence (captures + dumps) lands in docs/plans/2026-08-13-local-desktop-dictation/artifacts/M1/.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
. (Join-Path $PSScriptRoot "lib-tray.ps1")

$repo = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $repo "docs\plans\2026-08-13-local-desktop-dictation\artifacts\M1"
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
$storeExisted = Test-Path $storeFile
$storeBackup = if ($storeExisted) { [System.IO.File]::ReadAllBytes($storeFile) } else { $null }
$storeFileAlt = Join-Path $env:LOCALAPPDATA "com.viby.local\preferences.json"
$storeAltExisted = Test-Path $storeFileAlt
$storeAltBackup = if ($storeAltExisted) { [System.IO.File]::ReadAllBytes($storeFileAlt) } else { $null }
$proc = $null
$proc3 = $null
$proc4 = $null
$proc2 = $null
try {
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
# labels contain non-ASCII by design; build them from code points so this
# file stays pure ASCII and PowerShell 5.1 never misreads it
$optionsLabel = "Options" + [char]0x2026          # Options + ellipsis
$optionsTitle = "Viby " + [char]0x2014 + " Options"   # em-dash title


function Capture($name, $element = $null) {
    $left = 0; $top = 0; $width = 0; $height = 0
    if ($element) {
        $rect = $element.Current.BoundingRectangle
        $left = [int][Math]::Floor($rect.X)
        $top = [int][Math]::Floor($rect.Y)
        $width = [int][Math]::Ceiling($rect.Width)
        $height = [int][Math]::Ceiling($rect.Height)
    } elseif ($script:MenuHwnd -ne [System.IntPtr]::Zero) {
        $rect = [W2.Msaa]::GetWindowRectValue($script:MenuHwnd)
        $left = $rect.Left
        $top = $rect.Top
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
    }
    if ($width -le 0 -or $height -le 0) { return $null }
    $path = Join-Path $artifacts $name
    $b = New-Object System.Drawing.Bitmap($width, $height)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen($left, $top, 0, 0, $b.Size)
    $b.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $b.Dispose()
    $path
}





# --- 0. environment -------------------------------------------------------
$dpi = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction SilentlyContinue).AppliedDPI
$scale = if ($dpi) { "{0:P0}" -f ($dpi / 96) } else { "unknown" }
Note "windows-scaling: $scale"

# --- 0b. D7 identity: every package/bundle target is Viby ------------------
$pkg = Get-Content (Join-Path $repo "package.json") -Raw
$lock = Get-Content (Join-Path $repo "package-lock.json") -Raw
$cargo = Get-Content (Join-Path $repo "src-tauri\Cargo.toml") -Raw
$conf = Get-Content (Join-Path $repo "src-tauri\tauri.conf.json") -Raw
if ($pkg -notmatch '"name":\s*"viby"') { throw "npm package identity mismatch" }
if (([regex]::Matches($lock, '"name":\s*"viby"')).Count -lt 2) { throw "npm lock identity mismatch" }
if ($cargo -notmatch 'name = "viby"' -or $cargo -notmatch 'name = "viby_lib"') {
    throw "cargo identity mismatch"
}
if ($conf -notmatch '"productName":\s*"Viby"' -or $conf -notmatch '"identifier":\s*"com\.viby\.local"') {
    throw "tauri identity mismatch"
}
Note "identity-package-cargo-bundle: PASS (viby / viby_lib / Viby / com.viby.local)"
if (-not (Test-Path $exe)) { throw "viby.exe not built at $exe" }
Note "identity-exe-name: PASS (viby.exe)"

# --- 1. start -------------------------------------------------------------
if (Get-Process viby -ErrorAction SilentlyContinue) {
    throw "another Viby process is running; smoke refuses to terminate it"
}
$proc = Start-Process $exe -PassThru
Start-Sleep -Seconds 10
if ($proc.HasExited) { throw "app exited immediately with code $($proc.ExitCode)" }
Note "start: process alive (pid $($proc.Id))"
$mainWin = Find-First $root $CT::Window "Viby"
Note ("main-window-visible-at-rest: " + ($null -ne $mainWin -and $mainWin.Current.IsOffscreen -eq $false))


$script:MenuHwnd = [System.IntPtr]::Zero






# --- 2. tray menu ---------------------------------------------------------
if (-not (Open-TrayMenu)) { Capture "02-tray-menu-FAIL.png" | Out-Null; throw "tray context menu did not open" }
$labels = Get-TrayMenuItems
if (-not $labels) { Capture "02-tray-menu-FAIL.png" | Out-Null; throw "tray context menu did not open" }
$labels = @($script:MenuTexts | ForEach-Object { $_.Replace("&", "").Split("`t")[0] } | Where-Object { $_ })
Note ("tray-menu-items: " + ($labels -join " | "))
if ($labels.Count -ne 2 -or $labels[0] -ne $optionsLabel -or $labels[1] -ne "Close") {
    Capture "02-tray-menu-FAIL.png" | Out-Null
    throw "tray menu mismatch: $($labels -join ', ')"
}
Capture "02-tray-menu.png" | Out-Null

# --- 3. options window ----------------------------------------------------
Invoke-TrayMenuItem $optionsLabel
Start-Sleep -Seconds 3
$optionsWin = Find-First $root $CT::Window $optionsTitle
if (-not $optionsWin) { throw "options window did not open" }
Note "options-window: opened"
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr hwnd);' `
    -Name DpiSmoke -Namespace W4 -ErrorAction SilentlyContinue
$optionsDpi = [W4.DpiSmoke]::GetDpiForWindow([System.IntPtr]$optionsWin.Current.NativeWindowHandle)
Note "options-dpi: $optionsDpi"

# accessible names dump (screen-reader proxy)
$all = $optionsWin.FindAll([System.Windows.Automation.TreeScope]::Subtree,
    [System.Windows.Automation.Condition]::TrueCondition)
$dump = Join-Path $artifacts "03-options-uia-tree.txt"
$all | ForEach-Object {
    "{0} | {1} | {2}" -f $_.Current.ControlType.ProgrammaticName, $_.Current.Name, $_.Current.AutomationId
} | Out-File $dump
Note "uia-tree: $dump"
$accessibilityTargets = @(
    @{ Type = $CT::Edit; Name = "Dictation shortcut" },
    @{ Type = $CT::ComboBox; Name = "Input device" },
    @{ Type = $CT::Edit; Name = "Engine address" },
    @{ Type = $CT::CheckBox; Name = "Allow an engine on my local network" },
    @{ Type = $CT::Edit; Name = "Model name (optional)" },
    @{ Type = $CT::Edit; Name = "Language" },
    @{ Type = $CT::CheckBox; Name = "Send Enter after pasting (off by default)" },
    @{ Type = $CT::ComboBox; Name = "Bar position" },
    @{ Type = $CT::CheckBox; Name = "Show a provisional preview while speaking" },
    @{ Type = $CT::Button; Name = "Save" }
)
$accessibilityNames = @("required UIA controls:")
foreach ($target in $accessibilityTargets) {
    $control = Find-First $optionsWin $target.Type $target.Name
    if (-not $control) {
        throw "missing accessible control: $($target.Type.ProgrammaticName) '$($target.Name)'"
    }
    $accessibilityNames += "{0} | {1} | PASS" -f $target.Type.ProgrammaticName, $target.Name
}
$accessibilityNames | Out-File $dump -Append
Note "uia-control-names: PASS"
Capture "03-options.png" $optionsWin | Out-Null

# focus order (menu click may leave Options behind other windows; topmost wins)
Set-Topmost $optionsWin $true
Start-Sleep -Milliseconds 500
$focusLog = Join-Path $artifacts "04-focus-order.txt"
"" | Out-File $focusLog
for ($i = 0; $i -lt 15; $i++) {
    [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
    Start-Sleep -Milliseconds 200
    $focused = $AE::FocusedElement
    "{0}. {1} | {2}" -f ($i + 1), $focused.Current.ControlType.ProgrammaticName, $focused.Current.Name |
        Out-File $focusLog -Append
}
Note "focus-order: $focusLog"

# --- 4. shortcut conflict: persisted value must survive --------------------
$shortcutBox = $optionsWin.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Edit)))
$saveButton = Find-First $optionsWin $CT::Button "Save"
if ($saveButton.Current.IsEnabled) { throw "Save is enabled in clean state" }
Note "save-disabled-when-clean: PASS"

# WebView2 UIA coordinates are unreliable across monitors and ValuePattern
# bypasses DOM events; drive the form with real keys. The window is the
# active window after the tray-menu click.
function Focus-Shortcut($tries) {
    for ($i = 0; $i -lt $tries; $i++) {
        $fe = $AE::FocusedElement
        if ($fe -and $fe.Current.ControlType -eq $CT::Edit -and
            $fe.Current.Name -eq "Dictation shortcut") { return $true }
        [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
        Start-Sleep -Milliseconds 250
    }
    return $false
}
# materialize the store: retype the same shortcut (edit -> dirty -> Save on)
if (-not (Focus-Shortcut 12)) { throw "could not tab to the shortcut field" }
[System.Windows.Forms.SendKeys]::SendWait("^a")
[System.Windows.Forms.SendKeys]::SendWait("Ctrl{+}Shift{+}Space")
Start-Sleep -Milliseconds 500
if (-not $saveButton.Current.IsEnabled) { throw "Save stayed disabled after edit" }
Note "save-enabled-after-edit: PASS"

# Persist every supported bar position, then restore the default.
$barCases = @(
    @{ Key = "left"; Keys = @("{HOME}") },
    @{ Key = "right"; Keys = @("{END}") },
    @{ Key = "center"; Keys = @("{HOME}", "{DOWN}") }
)
foreach ($barCase in $barCases) {
    $barControl = Find-First $optionsWin $CT::ComboBox "Bar position"
    if (-not $barControl) { throw "bar position control missing for $($barCase.Key)" }
    $barControl.SetFocus()
    foreach ($key in $barCase.Keys) {
        [System.Windows.Forms.SendKeys]::SendWait($key)
    }
    [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
    Start-Sleep -Milliseconds 400
    if (-not $saveButton.Current.IsEnabled) {
        # SendKeys commit can land before the webview processes the previous
        # save; allow one longer settle before declaring failure.
        Start-Sleep -Milliseconds 800
    }
    if (-not $saveButton.Current.IsEnabled) {
        throw "bar position edit did not enable Save for $($barCase.Key)"
    }
    $saveButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Seconds 1
    $barSaved = (Get-Content $storeFile -Raw | ConvertFrom-Json).preferences.interface.bar_position
    if ($barSaved -ne $barCase.Key) {
        throw "bar position did not persist: expected $($barCase.Key), got $barSaved"
    }
    Note "bar-position-$($barCase.Key): PASS"
}
Start-Sleep -Seconds 2
Capture "04-saved.png" $optionsWin | Out-Null
$savedStatusText = $null
for ($attempt = 0; $attempt -lt 10 -and -not $savedStatusText; $attempt++) {
    $savedStatusText = $optionsWin.FindAll(
        [System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
        Where-Object { $_.Current.Name -eq "Saved" }
    if (-not $savedStatusText) { Start-Sleep -Milliseconds 300 }
}
if ($saveButton.Current.IsEnabled) { throw "Save stayed enabled after successful save" }
if (-not $savedStatusText) { throw "save status did not render exact 'Saved' copy" }
Note "status-after-save: Saved; save-disabled-after-save: PASS"

 # Engine and language card (D23): the local-network permission is off by
 # default, refused endpoints stay on their own field and never persist, and
 # an empty endpoint saves (R7, DESIGN).
 $permission = Find-First $optionsWin $CT::CheckBox "Allow an engine on my local network"
 if (-not $permission) { throw "local-network permission control missing" }
 $toggle = $permission.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
 if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
     throw "the local-network permission is not off by default"
 }
 $permissionHint = $optionsWin.FindAll(
     [System.Windows.Automation.TreeScope]::Subtree,
     (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
     Where-Object { $_.Current.Name -match "leaves this PC" }
 if (-not $permissionHint) { throw "the local-network warning is not rendered" }
 Note "local-network-permission: off by default, warning present"
 $endpointControl = Find-First $optionsWin $CT::Edit "Engine address"
 if (-not $endpointControl) { throw "engine address control missing" }
 foreach ($case in @(
         @{ Value = "http://8.8.8.8:8080"; Expect = "outside this PC"; Shot = "05-engine-public-refused.png" },
         @{ Value = "http://192.168.1.5:8080"; Expect = "local network"; Shot = "05-engine-private-refused.png" },
         @{ Value = "http://user:pw@127.0.0.1:8080"; Expect = "user name, password"; Shot = "05-engine-credentials-refused.png" })) {
     $endpointControl.SetFocus()
     [System.Windows.Forms.SendKeys]::SendWait("^a")
     [System.Windows.Forms.SendKeys]::SendWait($case.Value)
     [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
     Start-Sleep -Milliseconds 300
     $saveButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
     Start-Sleep -Milliseconds 900
     $endpointError = $optionsWin.FindAll(
         [System.Windows.Automation.TreeScope]::Subtree,
         (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
         Where-Object { $_.Current.Name -match $case.Expect }
     if (-not $endpointError) { throw "refused endpoint $($case.Value) did not render its field error" }
     $focused = $AE::FocusedElement
     if ($focused.Current.Name -ne "Engine address") {
         throw "refused endpoint left focus on '$($focused.Current.Name)', not the engine address"
     }
     $stored = (Get-Content $storeFile -Raw | ConvertFrom-Json).preferences
     if ($stored.engine -and $stored.engine.endpoint -eq $case.Value) { throw "refused endpoint $($case.Value) was persisted" }
     Capture $case.Shot $optionsWin | Out-Null
     Note "engine-endpoint-refused: PASS ($($case.Value) -> $($endpointError[0].Current.Name))"
 }
 $endpointControl.SetFocus()
 [System.Windows.Forms.SendKeys]::SendWait("^a")
 [System.Windows.Forms.SendKeys]::SendWait("{BACKSPACE}")
 [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
 Start-Sleep -Milliseconds 300
 $saveButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
 Start-Sleep -Seconds 1
 if ($saveButton.Current.IsEnabled) { throw "Save stayed enabled after saving an empty endpoint" }
 if ((Get-Content $storeFile -Raw | ConvertFrom-Json).preferences.engine.endpoint -ne "") {
     throw "an empty endpoint did not save"
 }
 Note "engine-endpoint-empty-save: PASS"


$saved = Get-Content $storeFile -Raw | ConvertFrom-Json
$before = $saved.preferences.shortcut
Note "shortcut-before-conflict: $before"
if ($saved.preferences.interface.bar_position -ne "center") {
    throw "bar_position not persisted with default 'center'"
}
Note "bar-position-persisted-default: PASS"
# conflict attempt: Ctrl+Esc is owned by Windows, registration must fail
if (-not (Focus-Shortcut 12)) { throw "could not return to the shortcut field" }
[System.Windows.Forms.SendKeys]::SendWait("^a")
[System.Windows.Forms.SendKeys]::SendWait("Ctrl{+}Esc")
Start-Sleep -Milliseconds 500
$saveButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Seconds 2
Capture "05-conflict-error.png" $optionsWin | Out-Null
$errorText = $optionsWin.FindAll([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
    Where-Object { $_.Current.Name -match "already registered" }
if (-not $errorText) { throw "conflict did not render an inline error" }
Note "conflict-inline-error: PASS ($($errorText[0].Current.Name))"
if ($saveButton.Current.IsEnabled) { throw "Save should stay disabled after conflict until edit" }
Note "save-disabled-after-conflict: PASS"
[W.K2]::keybd_event(0x11, 0, 0, 0)
[W.K2]::keybd_event(0x10, 0, 0, 0)
[W.K2]::keybd_event(0x20, 0, 0, 0)
[W.K2]::keybd_event(0x20, 0, 2, 0)
[W.K2]::keybd_event(0x10, 0, 2, 0)
[W.K2]::keybd_event(0x11, 0, 2, 0)
Start-Sleep -Seconds 1
$mainWindows = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window))) |
    Where-Object { $_.Current.Name -eq "Viby" }
if (-not $mainWindows -or $mainWindows[0].Current.IsOffscreen) {
    throw "previous shortcut no longer activates Viby after conflict"
}
Note "previous-shortcut-still-active: PASS"
Hide-Window $mainWindows[0]
Set-Topmost $optionsWin $true

# --- 4b. persistence failure: retry state with canonical copy ---------------
Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr a, int x, int y, int cx, int cy, uint f);
' -Name WinPos -Namespace W3 -ErrorAction SilentlyContinue

# recover from the conflict state first: stage a different shortcut so the
# persistence failure proves the previous registered shortcut is restored.
if (-not (Focus-Shortcut 12)) { throw "could not return to the shortcut field" }
[System.Windows.Forms.SendKeys]::SendWait("^a")
[System.Windows.Forms.SendKeys]::SendWait("Ctrl{+}Alt{+}Space")
Start-Sleep -Milliseconds 400

$storeDir = Split-Path $storeFile -Parent
$acl = Get-Acl $storeDir
$deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $env:USERNAME, "Write", "ContainerInherit,ObjectInherit", "None", "Deny")
$acl.AddAccessRule($deny)
Set-Acl $storeDir $acl
try {
    $saveButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Seconds 2
    $failText = $optionsWin.FindAll([System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
        Where-Object { $_.Current.Name -match "Couldn.t save settings\. Try again\." }
    if (-not $failText) { throw "persistence failure did not render the retry copy" }
    if (-not $saveButton.Current.IsEnabled) { throw "Save should stay enabled for retry" }
    Capture "06-save-failure.png" $optionsWin | Out-Null
    Note "persistence-failure-retry: PASS"
} finally {
    $acl.RemoveAccessRule($deny) | Out-Null
    Set-Acl $storeDir $acl
}
$optionsWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
Start-Sleep -Milliseconds 500
Open-TrayMenu | Out-Null
Get-TrayMenuItems | Out-Null
Invoke-TrayMenuItem $optionsLabel
Start-Sleep -Seconds 2
$optionsWin = Find-First $root $CT::Window $optionsTitle
if (-not $optionsWin) { throw "options window did not reopen for minimum-size traversal" }
Set-Topmost $optionsWin $true
$shortcutBox = Find-First $optionsWin $CT::Edit "Dictation shortcut"
$saveButton = Find-First $optionsWin $CT::Button "Save"
if (-not $shortcutBox -or -not $saveButton) { throw "minimum-size controls missing after reopen" }
# --- 4c. minimum client size: 480 x 480, full traversal, no clipping --------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClientSizeApi {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect rect);
}
'@ -ErrorAction SilentlyContinue

# Enable Save so the sticky footer is part of the keyboard traversal.
$shortcutBox.SetFocus()
[System.Windows.Forms.SendKeys]::SendWait("^a")
[System.Windows.Forms.SendKeys]::SendWait("Ctrl{+}Alt{+}Space")
[System.Windows.Forms.SendKeys]::SendWait("{TAB}")
Start-Sleep -Milliseconds 400
if (-not $saveButton.Current.IsEnabled) { throw "Save stayed disabled before minimum-size traversal" }

$hwnd = [System.IntPtr]$optionsWin.Current.NativeWindowHandle
$windowRect = New-Object ClientSizeApi+Rect
$clientRect = New-Object ClientSizeApi+Rect
[ClientSizeApi]::GetWindowRect($hwnd, [ref]$windowRect) | Out-Null
[ClientSizeApi]::GetClientRect($hwnd, [ref]$clientRect) | Out-Null
$outerWidth = ($windowRect.Right - $windowRect.Left) + 480 - ($clientRect.Right - $clientRect.Left)
$outerHeight = ($windowRect.Bottom - $windowRect.Top) + 480 - ($clientRect.Bottom - $clientRect.Top)
$minFocusLog = Join-Path $artifacts "07-min-size-focus-order.txt"
"" | Out-File $minFocusLog
$saveReached = $false
for ($i = 0; $i -lt 9; $i++) {
    [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
    Start-Sleep -Milliseconds 200
    $focused = $AE::FocusedElement
    if (-not $focused -or $focused.Current.IsOffscreen -or [string]::IsNullOrWhiteSpace($focused.Current.Name)) {
        throw "minimum-size focus target is clipped or unnamed at tab $($i + 1)"
    }
    "{0}. {1} | {2}" -f ($i + 1), $focused.Current.ControlType.ProgrammaticName, $focused.Current.Name |
        Out-File $minFocusLog -Append
    if ($focused.Current.Name -eq "Save") {
        $saveReached = $true
        Capture "07-min-size-480.png" $optionsWin | Out-Null
    }
}
if (-not $saveReached) {
    throw "minimum-size traversal did not reach sticky Save"
}
Note "min-size-480-traversal: $minFocusLog; client=480x480; sticky-save=PASS"

# --- 4d. Narrator section REMOVED 2026-08-15 (see header note). -------------
# --- 4e. forced-colors fallback ---------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HighContrastApi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct HIGHCONTRASTW {
        public uint cbSize;
        public uint dwFlags;
        public IntPtr scheme;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfoW(
        uint action, uint param, ref HIGHCONTRASTW value, uint flags);
}
'@ -ErrorAction SilentlyContinue
$hc = New-Object HighContrastApi+HIGHCONTRASTW
$hc.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][HighContrastApi+HIGHCONTRASTW])
[HighContrastApi]::SystemParametersInfoW(0x0042, $hc.cbSize, [ref]$hc, 0) | Out-Null
$hcBefore = $hc.dwFlags
try {
    $hcOn = New-Object HighContrastApi+HIGHCONTRASTW
    $hcOn.cbSize = $hc.cbSize
    $hcOn.dwFlags = $hcBefore -bor 0x00000001
    $hcOn.scheme = $hc.scheme
    [HighContrastApi]::SystemParametersInfoW(0x0043, $hc.cbSize, [ref]$hcOn, 0x0002) | Out-Null
    Start-Sleep -Seconds 3
    Capture "09-forced-colors.png" $optionsWin | Out-Null
    Note "forced-colors: captured"
} finally {
    $hcOff = New-Object HighContrastApi+HIGHCONTRASTW
    $hcOff.cbSize = $hc.cbSize
    $hcOff.dwFlags = $hcBefore
    $hcOff.scheme = $hc.scheme
    [HighContrastApi]::SystemParametersInfoW(0x0043, $hcOff.cbSize, [ref]$hcOff, 0x0002) | Out-Null
}
$after = (Get-Content $storeFile -Raw | ConvertFrom-Json).preferences.shortcut
Note "shortcut-after-conflict: $after"
if ($after -ne $before) { throw "conflict overwrote the persisted shortcut" }
Note "conflict-persists-previous: PASS"

# --- 5. restart: previous shortcut still the configured one ----------------
Set-Topmost $optionsWin $false
$optionsWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
Start-Sleep -Milliseconds 500
Open-TrayMenu | Out-Null
Get-TrayMenuItems | Out-Null
Invoke-TrayMenuItem "Close"
$proc.WaitForExit(5000) | Out-Null
if (-not $proc.HasExited) { throw "Close did not exit the process" }
Note ("close-exits: PASS (exit code " + $proc.ExitCode + ")")

$proc2 = Start-Process $exe -PassThru
Start-Sleep -Seconds 10
$stored = Get-Content $storeFile -Raw | ConvertFrom-Json
$persisted = $stored.preferences.shortcut
Note "shortcut-after-restart: $persisted"
if ($persisted -ne $before) { throw "restart lost the previous shortcut" }
Note "restart-keeps-shortcut: PASS"
if ($stored.preferences.interface.bar_position -ne "center") {
    throw "restart lost bar_position"
}
Note "restart-keeps-bar-position: PASS"

# store contents stay non-sensitive
$raw = Get-Content $storeFile -Raw
foreach ($banned in @("audio", "transcript", "history", "clipboard")) {
    if ($raw -match $banned) { throw "sensitive key '$banned' in store" }
}
Note "store-non-sensitive: PASS"

# final close
Open-TrayMenu | Out-Null
Get-TrayMenuItems | Out-Null
Invoke-TrayMenuItem "Close"
$proc2.WaitForExit(5000) | Out-Null
if (-not $proc2.HasExited) { throw "final Close did not exit the process" }
Note "final-close-exits: PASS"
# --- 5b. startup shortcut conflict remains actionable ----------------------
$startupConflict = Get-Content $storeFile -Raw | ConvertFrom-Json
$startupConflict.preferences.shortcut = "Ctrl+Esc"
[System.IO.File]::WriteAllText(
    $storeFile,
    ($startupConflict | ConvertTo-Json -Depth 8))
$proc4 = Start-Process $exe -PassThru
Start-Sleep -Seconds 10
if ($proc4.HasExited) { throw "startup-conflict process exited (code $($proc4.ExitCode))" }
Open-TrayMenu | Out-Null
Get-TrayMenuItems | Out-Null
Invoke-TrayMenuItem $optionsLabel
Start-Sleep -Seconds 3
$startupWin = Find-First $root $CT::Window $optionsTitle
if (-not $startupWin) { throw "options window did not open for startup conflict" }
$startupConflictText = $null
for ($attempt = 0; $attempt -lt 10 -and -not $startupConflictText; $attempt++) {
    $startupConflictText = $startupWin.FindAll(
        [System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
        Where-Object { $_.Current.Name -match "already registered" }
    if (-not $startupConflictText) { Start-Sleep -Milliseconds 500 }
}
Capture "10-startup-conflict.png" $startupWin | Out-Null
if (-not $startupConflictText) {
    throw "startup shortcut conflict did not render actionable copy"
}
$startupShortcut = Find-First $startupWin $CT::Edit "Dictation shortcut"
$startupSave = Find-First $startupWin $CT::Button "Save"
if (-not $startupShortcut -or -not $startupSave) {
    throw "startup conflict recovery controls are missing"
}
$startupShortcut.SetFocus()
[System.Windows.Forms.SendKeys]::SendWait("^a")
[System.Windows.Forms.SendKeys]::SendWait("Ctrl{+}Shift{+}Space")
[System.Windows.Forms.SendKeys]::SendWait("{TAB}")
Start-Sleep -Milliseconds 400
if (-not $startupSave.Current.IsEnabled) { throw "startup conflict did not enable Save after correction" }
$startupSave.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Seconds 1
$startupStatus = $startupWin.FindAll(
    [System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
    Where-Object { $_.Current.Name -eq "Saved" }
if (-not $startupStatus) { throw "startup conflict correction did not save" }
$startupStored = Get-Content $storeFile -Raw | ConvertFrom-Json
if ($startupStored.preferences.shortcut -ne "Ctrl+Shift+Space") {
    throw "startup conflict correction did not persist the replacement"
}
Note "startup-conflict-recovery: PASS (actionable conflict copy rendered); corrected-and-saved=PASS"
$startupWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
Start-Sleep -Milliseconds 500
Open-TrayMenu | Out-Null
Get-TrayMenuItems | Out-Null
Invoke-TrayMenuItem "Close"
$proc4.WaitForExit(5000) | Out-Null
if (-not $proc4.HasExited) { throw "startup-conflict app did not close" }


# --- 6. corrupt-store load recovery ----------------------------------------
[System.IO.File]::WriteAllText($storeFile, '{"preferences":')
[System.IO.File]::WriteAllText($storeFileAlt, '{"preferences":')
$proc3 = Start-Process $exe -PassThru
Start-Sleep -Seconds 10
if ($proc3.HasExited) { throw "corrupt-store process exited at startup (code $($proc3.ExitCode))" }
Open-TrayMenu | Out-Null
Get-TrayMenuItems | Out-Null
Invoke-TrayMenuItem $optionsLabel
Start-Sleep -Seconds 3
$loadFailWin = Find-First $root $CT::Window $optionsTitle
if (-not $loadFailWin) { throw "options window did not open for corrupt-store recovery" }
$loadFailureText = $null
for ($attempt = 0; $attempt -lt 10 -and -not $loadFailureText; $attempt++) {
    $loadFailureText = $loadFailWin.FindAll(
        [System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
        Where-Object { $_.Current.Name -match "Couldn.t load settings\. Review the values and save to start fresh\." }
    if (-not $loadFailureText) { Start-Sleep -Milliseconds 500 }
}
if (-not $loadFailureText) { throw "corrupt store did not render exact load-failed copy" }
$loadSave = $null
for ($attempt = 0; $attempt -lt 10 -and -not $loadSave; $attempt++) {
    $loadSave = @($loadFailWin.FindAll(
        [System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))) |
        Select-Object -First 1
    if (-not $loadSave) { Start-Sleep -Milliseconds 500 }
}
if (-not $loadSave -or $loadSave.Current.IsEnabled) {
    throw "corrupt store did not leave Save disabled"
}
# recovery: an edit re-enables Save and the save recreates a clean store
if (-not (Focus-Shortcut 10)) { throw "could not focus shortcut field for recovery save" }
[System.Windows.Forms.SendKeys]::SendWait("^a")
[System.Windows.Forms.SendKeys]::SendWait("Ctrl{+}Shift{+}Space")
Start-Sleep -Milliseconds 600
if (-not $loadSave.Current.IsEnabled) { throw "edit after load failure did not enable Save" }
$loadSave.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Seconds 2
$recovered = Get-Content $storeFile -Raw | ConvertFrom-Json
if ($recovered.preferences.shortcut -ne "Ctrl+Shift+Space") {
    throw "recovery save did not persist a fresh store"
}
Note "load-failure-recovery-save: PASS (fresh store persisted)"
Capture "10-load-failure.png" $loadFailWin | Out-Null
Note "load-failure-recovery: PASS ($($loadFailureText[0].Current.Name))"
$loadFailWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
Start-Sleep -Milliseconds 500
Open-TrayMenu | Out-Null
Get-TrayMenuItems | Out-Null
Invoke-TrayMenuItem "Close"
$proc3.WaitForExit(5000) | Out-Null
if (-not $proc3.HasExited) { throw "corrupt-store recovery app did not close" }
$report | Out-File (Join-Path $artifacts "smoke-report.txt")
Write-Host "`nSMOKE PASS"
} finally {
    foreach ($candidate in @($proc, $proc2, $proc3, $proc4)) {
        if ($candidate -and -not $candidate.HasExited) {
            Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item (Join-Path (Split-Path $storeFile) "preferences.bak") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path (Split-Path $storeFileAlt) "preferences.bak") -Force -ErrorAction SilentlyContinue
    if ($storeExisted) {
        [System.IO.File]::WriteAllBytes($storeFile, $storeBackup)
    } else {
        Remove-Item $storeFile -Force -ErrorAction SilentlyContinue
    }
    if ($storeAltExisted) {
        [System.IO.File]::WriteAllBytes($storeFileAlt, $storeAltBackup)
    } else {
        Remove-Item $storeFileAlt -Force -ErrorAction SilentlyContinue
    }
}
