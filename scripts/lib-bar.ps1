# Shared bar and flow helpers for the native bar smokes.
# Extracted from smoke-bar.ps1 2026-09-23; dot-source, do not copy.
# Requires: lib-tray.ps1 dot-sourced first (Note), and in scope $AE/$CT/$root,
# $storeFile/$storeExisted, $Endpoint (lib-engine.ps1), $exe, $logFile/$errFile,
# $webviewProfile, and $artifacts.

# Nominal bar window, in CSS pixels, from tauri.conf.json, and the safe edge
# inset from src-tauri/src/bar.rs. Both are scaled by the observed DPI.
$BAR_WIDTH = 420
$BAR_HEIGHT = 152
$BAR_INSET = 24

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, ref uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)] public static extern bool SystemParametersInfoRect(uint action, uint param, ref RECT2 data, uint winini);
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)] public static extern bool SystemParametersInfoBool(uint action, uint param, ref bool data, uint winini);
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)] public static extern bool SystemParametersInfoSet(uint action, uint param, System.IntPtr data, uint winini);
public struct RECT2 { public int Left, Top, Right, Bottom; }
' -Name Bar -Namespace VB -ErrorAction SilentlyContinue

function Get-WorkArea {
    $rect = New-Object VB.Bar+RECT2
    if (-not [VB.Bar]::SystemParametersInfoRect(0x0030, 0, [ref]$rect, 0)) {
        throw "SPI_GETWORKAREA failed"
    }
    return $rect
}

# SPI_GETCLIENTAREAANIMATION / SPI_SETCLIENTAREAANIMATION drive Chromium's
# prefers-reduced-motion inside WebView2.
function Get-Animations {
    $value = $true
    if (-not [VB.Bar]::SystemParametersInfoBool(0x1042, 0, [ref]$value, 0)) {
        throw "SPI_GETCLIENTAREAANIMATION failed"
    }
    return $value
}

function Set-Animations([bool]$on) {
    # SPI_SETCLIENTAREAANIMATION carries the value in pvParam itself, not
    # behind a pointer; passing a pointer would always read as TRUE.
    $value = if ($on) { [System.IntPtr]1 } else { [System.IntPtr]::Zero }
    # SPIF_UPDATEINIFILE | SPIF_SENDCHANGE, so running apps see the change
    if (-not [VB.Bar]::SystemParametersInfoSet(0x1043, 0, $value, 3)) {
        throw "SPI_SETCLIENTAREAANIMATION failed"
    }
    Start-Sleep -Milliseconds 500
    if ((Get-Animations) -ne $on) {
        throw "client area animations did not change to $on"
    }
}

function Write-Prefs($mutate) {
    if (-not $storeExisted) { throw "no preferences store at $storeFile; run Viby once first" }
    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    Set-EnginePrefs $prefs.preferences $Endpoint
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    # A store written before D16 has no discard shortcut; pin the default.
    $prefs.preferences | Add-Member -NotePropertyName discard_shortcut `
        -NotePropertyValue "Ctrl+Shift+Backspace" -Force
    $prefs.preferences.microphone = $null
    $prefs.preferences.interface.show_preview = $true
    $prefs.preferences.interface.bar_position = "center"
    # The confirmation run opts in explicitly; every other run expects the
    # default off, and a store written before the field existed lacks it.
    $prefs.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
        -NotePropertyValue $false -Force
    if ($mutate) { & $mutate $prefs }
    # serde_json rejects a BOM; write strict UTF-8
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))
}

function Start-Viby {
    if (Get-Process viby -ErrorAction SilentlyContinue) {
        throw "another Viby process is running; smoke refuses to terminate it"
    }
    Remove-Item $logFile, $errFile -Force -ErrorAction SilentlyContinue
    # The capsule is deliberately never activated, and WebView2 keeps an
    # unfocused document's accessibility tree minimal until a client asks for
    # it. A live screen reader would turn it on; since Narrator cannot run
    # here, this flag turns on exactly the same full tree so the accessible
    # names and roles the announcements rely on are observable.
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--force-renderer-accessibility"
    # WebView2 shares one browser process per user-data folder. A webview left
    # over from another Viby launch would be reused *without* the flag above,
    # and the accessible names would silently stay absent. A folder of our own
    # guarantees a fresh browser process that honours it.
    $env:WEBVIEW2_USER_DATA_FOLDER = $webviewProfile
    # cmd redirection flushes eagerly; -RedirectStandardOutput only on exit.
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList ('/c ""{0}" > "{1}" 2> "{2}""' -f $exe, $logFile, $errFile) | Out-Null
    Start-Sleep -Seconds 6
    # The preflight refuses to run beside a pre-existing instance, so this is
    # our process. Own the PID: cleanup must never kill a user's instance.
    $started = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $started) { throw "viby.exe did not start" }
    $script:viby = $started
}

function Stop-Viby {
    if ($script:viby -and -not $script:viby.HasExited) {
        Stop-Process -Id $script:viby.Id -Force -ErrorAction SilentlyContinue
        $script:viby.WaitForExit(5000) | Out-Null
    }
    $script:viby = $null
    # the OS needs a beat to release the killed process's hotkey registration
    Start-Sleep -Seconds 2
}

function Hold-Down {
    [VB.Bar]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [VB.Bar]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [VB.Bar]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
}

function Hold-Up {
    [VB.Bar]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [VB.Bar]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [VB.Bar]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

function Send-Key([byte]$key) {
    [VB.Bar]::keybd_event($key, 0, 0, [System.UIntPtr]::Zero)
    [VB.Bar]::keybd_event($key, 0, 2, [System.UIntPtr]::Zero)
}

function Click-At([int]$x, [int]$y) {
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
    [VB.Bar]::mouse_event(0x0002, 0, 0, 0, 0)  # left down
    [VB.Bar]::mouse_event(0x0004, 0, 0, 0, 0)  # left up
}

function Get-CleanLog {
    (Get-Content $logFile -ErrorAction SilentlyContinue) -replace "$([char]27)\[[0-9;]*m", ''
}

function Get-FlowStates {
    $states = @()
    foreach ($line in Get-CleanLog) {
        if ($line -match 'flow state.*state=(\w+)') {
            if ($states.Count -eq 0 -or $states[-1] -ne $Matches[1]) { $states += $Matches[1] }
        }
    }
    return $states
}

function Wait-ForState($state, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-FlowStates) -contains $state) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Assert-NoFinalDelivered($label) {
    $final = @(Get-CleanLog | Where-Object { $_ -match 'flow final' })
    if ($final.Count -gt 0) { throw "$label delivered a final result: $($final -join ' | ')" }
}

function Assert-Cancelled($label) {
    if (-not (Get-CleanLog | Where-Object { $_ -match 'state=Idle' -and $_ -match 'Some\("Canceled' })) {
        throw "$label did not record the cancellation message"
    }
}

# The bar is the only window titled exactly "Viby"; Options is "Viby - Options".
function Get-BarWindow {
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)))
    foreach ($w in $windows) {
        if ($w.Current.Name -eq "Viby" -and $w.Current.ProcessId -eq $script:viby.Id) { return $w }
    }
    return $null
}

# Whatever currently owns the foreground, for diagnostics. A fullscreen game or
# an elevated window swallows injected input, and then no shortcut ever reaches
# Viby — a failure that has nothing to do with the bar.
function Get-ForegroundInfo {
    $owner = 0
    $handle = [VB.Bar]::GetForegroundWindow()
    [void][VB.Bar]::GetWindowThreadProcessId($handle, [ref]$owner)
    $process = Get-Process -Id $owner -ErrorAction SilentlyContinue
    return ("pid={0} name={1}" -f $owner, $process.ProcessName)
}

function Wait-ForBar($timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $bar = Get-BarWindow
        if ($bar -and -not $bar.Current.IsOffscreen) { return $bar }
        Start-Sleep -Milliseconds 200
    }
    $trace = @(Get-CleanLog).Count
    $detail = "the capsule window never appeared (log lines={0}, foreground {1}). " +
        "An empty log means the injected shortcut never reached Viby: a fullscreen " +
        "game or an elevated foreground window blocks injected input."
    throw ($detail -f $trace, (Get-ForegroundInfo))
}

# The capsule lingers so the outcome is readable, then returns to the tray.
# Window visibility is read from Win32, not from a cached UIA snapshot.
function Assert-BarAtRest($label, $timeoutSeconds = 8) {
    $bar = Get-BarWindow
    if (-not $bar) { return }
    $handle = [System.IntPtr]$bar.Current.NativeWindowHandle
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not [VB.Bar]::IsWindowVisible($handle)) {
            Note "${label}: capsule returned to the tray"
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "${label}: the capsule stayed on screen after the flow ended"
}

function Get-BarElements($bar) {
    $items = @()
    $all = $bar.FindAll([System.Windows.Automation.TreeScope]::Subtree,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        $items += [pscustomobject]@{
            Type = $el.Current.ControlType.ProgrammaticName
            Name = $el.Current.Name
            Element = $el
        }
    }
    return $items
}

# Chromium computes accessible names asynchronously after the tree is turned
# on, so a single read can legitimately return unnamed panes on a cold start.
# The contract is that the name appears, not that it appears within one sample:
# poll, and only then fail with the full dump.
function Wait-ForName($bar, $pattern, $label, $timeoutSeconds = 10) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $elements = @()
    while ((Get-Date) -lt $deadline) {
        $current = Get-BarWindow
        if ($current) {
            $elements = Get-BarElements $current
            if ($elements | Where-Object { $_.Name -like $pattern }) { return $elements }
        }
        Start-Sleep -Milliseconds 250
    }
    throw ("{0}: no element matching '{1}' after {2}s in: {3}" -f $label, $pattern,
        $timeoutSeconds, (($elements | ForEach-Object { "$($_.Type)='$($_.Name)'" }) -join ' | '))
}

function Assert-Name($elements, $pattern, $label) {
    if (-not ($elements | Where-Object { $_.Name -like $pattern })) {
        throw ("{0}: no element matching '{1}' in: {2}" -f $label, $pattern,
            (($elements | ForEach-Object { "$($_.Type)='$($_.Name)'" }) -join ' | '))
    }
}

function Assert-NoName($elements, $pattern, $label) {
    if ($elements | Where-Object { $_.Name -like $pattern }) {
        throw "${label}: unexpected element matching '$pattern'"
    }
}

function Get-Button($elements, $name) {
    ($elements | Where-Object { $_.Type -eq "ControlType.Button" -and $_.Name -eq $name } |
        Select-Object -First 1)
}

# UIA invoke, not a mouse click: clicking would activate the capsule and the
# focus-preservation assertions would stop meaning anything.
function Invoke-BarButton($elements, $name) {
    $button = Get-Button $elements $name
    if (-not $button) { throw "the capsule has no '$name' button" }
    $button.Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Capture($name, $element) {
    $rect = $element.Current.BoundingRectangle
    $left = [int][Math]::Floor($rect.X)
    $top = [int][Math]::Floor($rect.Y)
    $width = [int][Math]::Ceiling($rect.Width)
    $height = [int][Math]::Ceiling($rect.Height)
    if ($width -le 0 -or $height -le 0) { return $null }
    $path = Join-Path $artifacts $name
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
    return $path
}

function Assert-Geometry($bar, $position, $work) {
    $rect = $bar.Current.BoundingRectangle
    $width = [Math]::Round($rect.Width)
    $height = [Math]::Round($rect.Height)
    $scale = $width / $BAR_WIDTH
    if ([Math]::Abs($height - $BAR_HEIGHT * $scale) -gt 2) {
        throw "capsule height $height does not match $BAR_HEIGHT at scale $scale"
    }
    $inset = [Math]::Round($BAR_INSET * $scale)
    $expectedBottom = $work.Bottom - $inset
    $bottom = [Math]::Round($rect.Y + $rect.Height)
    if ([Math]::Abs($bottom - $expectedBottom) -gt 2) {
        throw "$position capsule bottom $bottom is not the safe inset above the work area ($expectedBottom)"
    }
    $expectedX = switch ($position) {
        "left" { $work.Left + $inset }
        "right" { $work.Right - $width - $inset }
        default { $work.Left + [Math]::Round(($work.Right - $work.Left - $width) / 2) }
    }
    if ([Math]::Abs([Math]::Round($rect.X) - $expectedX) -gt 2) {
        throw "$position capsule x $([Math]::Round($rect.X)) is not $expectedX"
    }
    Note ("position-{0}: PASS (x={1} bottom={2} inset={3} scale={4})" -f `
        $position, [Math]::Round($rect.X), $bottom, $inset, $scale)
}
