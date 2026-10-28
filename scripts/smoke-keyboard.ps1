# M3 keyboard smoke (D16): press-once activation, keyboard-only resolution of
# the waiting step, and the discard shortcut in Options. TESTPLAN rows:
#   R1, S11 activation mode      K1 (press-once), K3 (hold, then the switch)
#   R4, S11 keyboard resolution  K1 (accept), K2 (discard)
#   R7 discard shortcut          K1/K2 (inert outside the waiting step),
#                                K3 (Options refusal, persistence, restart)
#
# Evidence channels: the app's own tracing log (flow states, confirmation
# outcome), the real bar window through UIA/Win32, Options through UIA and
# real keys, and Windows' per-app microphone usage record
# (CapabilityAccessManager\ConsentStore\microphone). That record is written by
# the OS audio stack, not by Viby: LastUsedTimeStop is 0 while the capture
# stream is open and becomes the close time when it is released.
#
# The flow runs are keyboard-only: the pointer is parked away from the dock
# before Viby starts and is never moved or clicked while a take is live. The
# tray menu in K3 is not part of any take.
#
# Narrator announcement capture and the 200% scaling pass are NOT part of this
# script and must not be added (user decision 2026-08-15, see AGENTS.md).
#
# Run from WSL:
#   powershell.exe -ExecutionPolicy Bypass -File scripts\smoke-keyboard.ps1 `
#       -ModelPath C:\openai-whisper\ggml-base-q5_1.bin

param(
    [string]$ModelPath = "C:\openai-whisper\ggml-base-q5_1.bin",
    [string]$Variant = "base-q5_1"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
. (Join-Path $PSScriptRoot "lib-tray.ps1")

$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement

$repo = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $repo "docs\plans\2026-08-13-local-desktop-dictation\artifacts\M3"
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
$storeExisted = Test-Path $storeFile
$storeBackup = if ($storeExisted) { [System.IO.File]::ReadAllBytes($storeFile) } else { $null }
$logFile = Join-Path $env:TEMP "viby-bar-trace.log"
$errFile = Join-Path $env:TEMP "viby-bar-trace.err"
$viby = $null
$webviewProfile = Join-Path $env:TEMP "viby-smoke-webview"

. (Join-Path $PSScriptRoot "lib-bar.ps1")

# labels contain non-ASCII by design; build them from code points so this
# file stays pure ASCII and PowerShell 5.1 never misreads it
$optionsLabel = "Options" + [char]0x2026
$optionsTitle = "Viby " + [char]0x2014 + " Options"

$DICTATION = [byte[]](0x11, 0x10, 0x20)    # Ctrl+Shift+Space
$DISCARD = [byte[]](0x11, 0x10, 0x08)      # Ctrl+Shift+Backspace, the default
$DISCARD_NEW = [byte[]](0x11, 0x10, 0x78)  # Ctrl+Shift+F9, saved through Options
$DISCARD_NEW_TEXT = "Ctrl+Shift+F9"

# One real tap: every key down, a human-length beat, every key up in reverse.
function Send-Chord([byte[]]$keys) {
    foreach ($key in $keys) { [VB.Bar]::keybd_event($key, 0, 0, [System.UIntPtr]::Zero) }
    Start-Sleep -Milliseconds 80
    for ($i = $keys.Count - 1; $i -ge 0; $i--) {
        [VB.Bar]::keybd_event($keys[$i], 0, 2, [System.UIntPtr]::Zero)
    }
}

# --- microphone, as Windows records it -----------------------------------
$micKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged\" +
    ($exe -replace '\\', '#')

function Get-MicUsage {
    $p = Get-ItemProperty -LiteralPath $micKey -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    return [pscustomobject]@{ Start = [long]$p.LastUsedTimeStart; Stop = [long]$p.LastUsedTimeStop }
}

function Test-MicOpen {
    $usage = Get-MicUsage
    return ($null -ne $usage -and $usage.Start -gt $usage.Stop)
}

function Wait-Mic([bool]$open, $label, $timeoutSeconds = 5) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-MicOpen) -eq $open) { return }
        Start-Sleep -Milliseconds 50
    }
    $want = if ($open) { "open" } else { "closed" }
    throw "${label}: the microphone was not $want within ${timeoutSeconds}s (usage: $(Get-MicUsage))"
}

# --- the flow, read from a mark in the trace --------------------------------
# A single process runs several takes here, so "has the log ever said X" is not
# enough; every wait reads only what was logged after the action it follows.
function Get-LogMark { return @(Get-CleanLog).Count }

function Get-StatesSince([int]$mark) {
    $lines = @(Get-CleanLog)
    $states = @()
    for ($i = $mark; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'flow state.*state=(\w+)') { $states += $Matches[1] }
    }
    return $states
}

function Wait-ForStateSince([int]$mark, $state, $label, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-StatesSince $mark) -contains $state) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "${label}: never reached $state (states since mark: $((Get-StatesSince $mark) -join ' -> '))"
}

function Get-LinesSince([int]$mark, $pattern) {
    $lines = @(Get-CleanLog)
    $found = @()
    for ($i = $mark; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { $found += $lines[$i] }
    }
    return $found
}

# --- the pointer stays out of it --------------------------------------------
function Park-Pointer {
    $work = Get-WorkArea
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($work.Left + 40), ($work.Top + 40))
    $script:parked = [System.Windows.Forms.Cursor]::Position
}

function Assert-PointerOutsideDock($label) {
    $bar = Get-BarWindow
    $pointer = [System.Windows.Forms.Cursor]::Position
    if ($bar -and -not $bar.Current.IsOffscreen) {
        $rect = $bar.Current.BoundingRectangle
        if ($pointer.X -ge $rect.X -and $pointer.X -lt $rect.X + $rect.Width -and
            $pointer.Y -ge $rect.Y -and $pointer.Y -lt $rect.Y + $rect.Height) {
            throw "${label}: the pointer is inside the dock at $($pointer.X),$($pointer.Y)"
        }
    }
    if ($pointer -ne $script:parked) {
        throw "${label}: the pointer moved from $($script:parked) to $pointer during a keyboard-only run"
    }
}

# A press-once take on the keyboard alone, from rest to the waiting step:
# the first tap opens the microphone and the take survives the key's release;
# the second tap closes it, and not before. Returns the mark at Confirming.
function Invoke-PressOnceTake($label) {
    if (Test-MicOpen) { throw "${label}: the microphone is open before any press" }
    $mark = Get-LogMark
    Send-Chord $DICTATION
    Wait-ForStateSince $mark "Recording" $label 15
    Wait-Mic $true "$label first tap"
    Assert-PointerOutsideDock "$label recording"
    # The key is already up. Hold mode would have ended the take on release;
    # press-once must keep it open.
    $deadline = (Get-Date).AddMilliseconds(1500)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-MicOpen)) { throw "${label}: the microphone closed before the second press" }
        $states = @(Get-StatesSince $mark)
        if ($states[-1] -ne "Recording") {
            throw "${label}: releasing the key ended the take ($($states -join ' -> '))"
        }
        Start-Sleep -Milliseconds 100
    }
    Note "$label-release-keeps-recording: PASS (microphone open 1.5 s after the key was released)"

    # R7: the discard shortcut is inert outside the waiting step - it must not
    # cancel a live capture the way the dock's own discard control does.
    $discardMark = Get-LogMark
    Send-Chord $DISCARD
    Start-Sleep -Milliseconds 800
    if (-not (Get-LinesSince $discardMark 'discard shortcut pressed')) {
        throw "${label}: the discard press never reached Viby; the inert check would prove nothing"
    }
    $after = @(Get-StatesSince $discardMark)
    if ($after.Count -gt 0 -or -not (Test-MicOpen)) {
        throw "${label}: the discard shortcut changed a live capture ($($after -join ' -> '))"
    }
    Note "$label-discard-inert-while-recording: PASS"

    $beforeSecond = [DateTime]::UtcNow.ToFileTimeUtc()
    if (-not (Test-MicOpen)) { throw "${label}: the microphone closed before the second press" }
    $endMark = Get-LogMark
    Send-Chord $DICTATION
    Wait-Mic $false "$label second tap"
    $usage = Get-MicUsage
    if ($usage.Stop -lt $beforeSecond) {
        throw "${label}: Windows recorded the microphone closing before the second press ($($usage.Stop) < $beforeSecond)"
    }
    Note ("{0}-second-tap-closes-microphone: PASS (closed {1} ms after the press began)" -f `
        $label, [Math]::Round(($usage.Stop - $beforeSecond) / 10000))
    Wait-ForStateSince $endMark "Processing" $label 15
    Wait-ForStateSince $endMark "Confirming" $label 180
    $bar = Wait-ForBar 10
    Wait-ForName $bar "*Ready to insert*" "$label waiting step" | Out-Null
    Assert-PointerOutsideDock "$label confirming"
    return (Get-LogMark)
}

# Nothing may follow a resolution: no new take, no refusal notice, and the
# microphone stays closed.
function Assert-NoNewTake([int]$mark, $label) {
    Start-Sleep -Milliseconds 1500
    $late = @(Get-StatesSince $mark) | Where-Object { $_ -in @("Loading", "Recording", "Processing") }
    if ($late) { throw "${label}: the resolving press started a new take ($($late -join ' -> '))" }
    if (Get-LinesSince $mark 'flow busy') { throw "${label}: the resolving press was refused as busy" }
    if (Test-MicOpen) { throw "${label}: the microphone reopened after the resolution" }
}

# --- Options, driven with real keys ------------------------------------------
function Open-Options($label) {
    $script:MenuHwnd = [System.IntPtr]::Zero
    if (-not (Open-TrayMenu)) { throw "${label}: the tray context menu did not open" }
    if (-not (Get-TrayMenuItems)) { throw "${label}: the tray context menu has no items" }
    Invoke-TrayMenuItem $optionsLabel
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $win = Find-First $root $CT::Window $optionsTitle
        if ($win) {
            $field = Find-First $win $CT::Edit "Discard shortcut"
            # Controls stay disabled until the stored preferences are loaded.
            if ($field -and $field.Current.IsEnabled) {
                Set-Topmost $win $true
                return $win
            }
        }
        Start-Sleep -Milliseconds 300
    }
    throw "${label}: Options did not open with a loaded Discard shortcut field"
}

function Close-Options($win) {
    $win.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Start-Sleep -Seconds 1
}

function Get-ConfirmBox($win) {
    $win.FindAll([System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::CheckBox))) |
        Where-Object { $_.Current.Name -like "Confirm before inserting*" } | Select-Object -First 1
}

function Get-FieldValue($win, $name) {
    $field = Find-First $win $CT::Edit $name
    if (-not $field) { throw "Options has no '$name' field" }
    return $field.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}

# Typing goes wherever the keyboard focus is. Refuse to send a single key
# unless it is the intended control, so a lost focus can never type into the
# user's own window.
function Focus-Control($win, $element, $label) {
    Set-Topmost $win $true
    $element.SetFocus()
    Start-Sleep -Milliseconds 300
    $focused = $AE::FocusedElement
    if (-not $focused -or $focused.Current.Name -ne $element.Current.Name -or
        $focused.Current.ControlType -ne $element.Current.ControlType) {
        throw "${label}: could not focus '$($element.Current.Name)'; refusing to type"
    }
}

function Set-DiscardText($win, $sendKeysText, $label) {
    $field = Find-First $win $CT::Edit "Discard shortcut"
    Focus-Control $win $field $label
    [System.Windows.Forms.SendKeys]::SendWait("^a")
    [System.Windows.Forms.SendKeys]::SendWait($sendKeysText)
    Start-Sleep -Milliseconds 400
}

function Invoke-Save($win, $label) {
    $save = Find-First $win $CT::Button "Save"
    if (-not $save.Current.IsEnabled) { throw "${label}: Save is disabled after an edit" }
    $save.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Seconds 2
}

function Get-TextMatching($win, $pattern) {
    $win.FindAll([System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
        Where-Object { $_.Current.Name -match $pattern } | Select-Object -First 1
}

# A refusal is only actionable if it lands on the control that has to change:
# the page moves keyboard focus to the field it marked invalid.
function Assert-FocusOn($name, $label) {
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        $focused = $AE::FocusedElement
        if ($focused -and $focused.Current.Name -eq $name) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "${label}: the refusal focused '$($AE::FocusedElement.Current.Name)', not '$name'"
}

function Get-StoredPrefs { (Get-Content $storeFile -Raw | ConvertFrom-Json).preferences }

try {
    if (-not (Test-Path $exe)) { throw "release executable not found: $exe (run cargo tauri build)" }
    if (-not (Test-Path $ModelPath)) { throw "model file not found: $ModelPath" }
    Note ("foreground-at-start: " + (Get-ForegroundInfo))
    Note "microphone-record: $micKey"

    # --- K1. press-once take, accepted with the dictation shortcut ----------
    Write-Prefs {
        param($p)
        $p.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
            -NotePropertyValue $true -Force
    }
    Park-Pointer
    Start-Viby
    $mark = Invoke-PressOnceTake "k1"
    Send-Chord $DICTATION
    Wait-ForStateSince $mark "Idle" "k1 accept" 10
    if (-not (Get-LinesSince $mark 'flow confirmation.*accepted=true')) {
        throw "k1: the dictation shortcut did not accept the waiting transcript"
    }
    Assert-NoNewTake $mark "k1 accept"
    Assert-PointerOutsideDock "k1 resolved"
    Assert-BarAtRest "k1-accept"
    Note "k1-keyboard-accept: PASS (accepted=true, no new take, pointer untouched)"
    Stop-Viby

    # --- K2. press-once take, discarded with the discard shortcut ------------
    Write-Prefs {
        param($p)
        $p.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
            -NotePropertyValue $true -Force
    }
    Park-Pointer
    Start-Viby
    $mark = Invoke-PressOnceTake "k2"
    Send-Chord $DISCARD
    Wait-ForStateSince $mark "Idle" "k2 discard" 10
    if (-not (Get-LinesSince $mark 'flow confirmation.*accepted=false')) {
        throw "k2: the discard shortcut did not discard the waiting transcript"
    }
    Assert-NoNewTake $mark "k2 discard"
    Assert-PointerOutsideDock "k2 resolved"
    Assert-BarAtRest "k2-discard"
    Note "k2-keyboard-discard: PASS (accepted=false, no new take, pointer untouched)"
    # R7: at rest the discard shortcut does nothing either - no dock, no state.
    $idleMark = Get-LogMark
    Send-Chord $DISCARD
    Start-Sleep -Milliseconds 1200
    if (-not (Get-LinesSince $idleMark 'discard shortcut pressed')) {
        throw "k2: the idle discard press never reached Viby; the inert check would prove nothing"
    }
    $bar = Get-BarWindow
    if (@(Get-StatesSince $idleMark).Count -gt 0 -or
        ($bar -and [VB.Bar]::IsWindowVisible([System.IntPtr]$bar.Current.NativeWindowHandle))) {
        throw "k2: the discard shortcut acted at rest"
    }
    Note "k2-discard-inert-at-rest: PASS"
    Stop-Viby

    # --- K3. hold mode, then Options switches it without a restart ----------
    Write-Prefs $null
    Start-Viby
    if (Test-MicOpen) { throw "k3: the microphone is open before any press" }
    $mark = Get-LogMark
    Hold-Down
    try {
        Wait-ForStateSince $mark "Recording" "k3 hold" 15
        Wait-Mic $true "k3 hold"
        Start-Sleep -Milliseconds 1500
        if (-not (Test-MicOpen)) { throw "k3: the microphone closed while the key was held" }
        $beforeRelease = [DateTime]::UtcNow.ToFileTimeUtc()
    } finally {
        Hold-Up
    }
    Wait-Mic $false "k3 release"
    if ((Get-MicUsage).Stop -lt $beforeRelease) {
        throw "k3: Windows recorded the microphone closing before the release"
    }
    Wait-ForStateSince $mark "Processing" "k3 hold" 15
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $states = @(Get-StatesSince $mark)
        if ($states[-1] -in @("Idle", "Error")) { break }
        Start-Sleep -Milliseconds 250
    }
    $states = @(Get-StatesSince $mark)
    if ($states -contains "Confirming") { throw "k3: hold mode waited for a confirmation" }
    if ($states[-1] -notin @("Idle", "Error")) { throw "k3: hold take never ended ($($states -join ' -> '))" }
    Assert-BarAtRest "k3-hold"
    Note ("k3-hold-release-ends-take: PASS (" + ($states -join " -> ") + ")")

    $options = Open-Options "k3"
    $initial = Get-FieldValue $options "Discard shortcut"
    if ($initial -ne "Ctrl+Shift+Backspace") { throw "k3: Discard shortcut shows '$initial', not the stored default" }
    Note "k3-options-discard-field: PASS ($initial)"

    # The same chord as the dictation shortcut, written in another order:
    # equality is on the parsed shortcut, not the string.
    Set-DiscardText $options "Shift{+}Ctrl{+}Space" "k3 duplicate"
    Invoke-Save $options "k3 duplicate"
    $refusal = Get-TextMatching $options "must be different from the dictation shortcut"
    if (-not $refusal) { throw "k3: a discard shortcut equal to the dictation shortcut was not refused inline" }
    Assert-FocusOn "Discard shortcut" "k3 duplicate"
    $shot = Capture "options-discard-duplicate.png" $options
    Note "capture-options-duplicate: $shot"
    if ((Find-First $options $CT::Button "Save").Current.IsEnabled) {
        throw "k3: Save stayed enabled after the refusal"
    }
    if ((Get-StoredPrefs).discard_shortcut -ne "Ctrl+Shift+Backspace") {
        throw "k3: the refused discard shortcut reached the store"
    }
    Note ("k3-duplicate-refused: PASS (" + $refusal.Current.Name + "; store kept Ctrl+Shift+Backspace)")

    Set-DiscardText $options "Backspace" "k3 invalid"
    Invoke-Save $options "k3 invalid"
    $invalid = Get-TextMatching $options "at least one modifier"
    if (-not $invalid) { throw "k3: a discard shortcut without a modifier was not refused inline" }
    Assert-FocusOn "Discard shortcut" "k3 invalid"
    if ((Get-StoredPrefs).discard_shortcut -ne "Ctrl+Shift+Backspace") {
        throw "k3: the invalid discard shortcut reached the store"
    }
    Note ("k3-invalid-refused: PASS (" + $invalid.Current.Name + ")")

    Set-DiscardText $options ($DISCARD_NEW_TEXT -replace '\+', '{+}') "k3 valid"
    $confirm = Get-ConfirmBox $options
    if (-not $confirm) { throw "k3: Options has no confirm-before-inserting control" }
    Focus-Control $options $confirm "k3 confirm"
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Start-Sleep -Milliseconds 400
    $toggle = $confirm.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
    if ($toggle -ne [System.Windows.Automation.ToggleState]::On) { throw "k3: the confirm control did not turn on" }
    Invoke-Save $options "k3 valid"
    if (-not (Get-TextMatching $options "^Saved$")) { throw "k3: the valid save did not report Saved" }
    $stored = Get-StoredPrefs
    if ($stored.discard_shortcut -ne $DISCARD_NEW_TEXT -or -not $stored.insertion.confirm_before_insert) {
        throw "k3: the store holds discard='$($stored.discard_shortcut)' confirm=$($stored.insertion.confirm_before_insert)"
    }
    Note "k3-valid-saved: PASS (discard=$DISCARD_NEW_TEXT, confirm_before_insert=true)"
    Close-Options $options

    # Same process: the saved preference must already mean press-once, and
    # the saved discard shortcut must already be the live one.
    Park-Pointer
    $mark = Invoke-PressOnceTake "k3-switched"
    Send-Chord $DISCARD_NEW
    Wait-ForStateSince $mark "Idle" "k3 new discard" 10
    if (-not (Get-LinesSince $mark 'flow confirmation.*accepted=false')) {
        throw "k3: the saved discard shortcut did not discard the waiting transcript"
    }
    Assert-NoNewTake $mark "k3 new discard"
    Assert-BarAtRest "k3-switched"
    Note "k3-mode-switch-without-restart: PASS (hold -> press-once in pid $($script:viby.Id); saved discard shortcut live)"
    Stop-Viby

    # --- restart: the saved values are the loaded ones -----------------------
    Start-Viby
    $options = Open-Options "k3 restart"
    $reloaded = Get-FieldValue $options "Discard shortcut"
    $confirm = Get-ConfirmBox $options
    $toggle = $confirm.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
    if ($reloaded -ne $DISCARD_NEW_TEXT -or $toggle -ne [System.Windows.Automation.ToggleState]::On) {
        throw "k3: after restart Options shows discard='$reloaded' confirm=$toggle"
    }
    $shot = Capture "options-discard-restart.png" $options
    Note "capture-options-restart: $shot"
    Note "k3-persisted-across-restart: PASS (discard=$reloaded, confirm=On)"
    Close-Options $options
    Stop-Viby

    Note "`nSMOKE PASS"
} finally {
    Stop-Viby
    if ($storeExisted) { [System.IO.File]::WriteAllBytes($storeFile, $storeBackup) }
    Remove-Item (Join-Path (Split-Path $storeFile) "preferences.bak") -Force -ErrorAction SilentlyContinue
    Remove-Item $webviewProfile -Recurse -Force -ErrorAction SilentlyContinue
    $report | Set-Content (Join-Path $artifacts "smoke-keyboard-report.txt")
}
