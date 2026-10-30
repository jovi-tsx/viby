# Teardown probe: does the dock leave the screen before the process does?
#
# `scripts/probe-whiteflash.ps1` answered a narrower question - it watched the
# cancel-during-capture path through a 260 px strip along the bottom of the work
# area. Two things were out of its reach: an artefact painted above that strip,
# and the three `CloseDecision::ExitClean` windows in which the dock is on
# screen with no active flow. This probe covers both.
#
# Scenarios, all of them `ExitClean` in `flow::on_close_requested`:
#   B  error linger   (6 s)   deterministic: an unreadable model path puts the
#                             flow in `Error` on the first press, with no speech
#                             and no model load to wait for. This one decides
#                             the gate.
#   C  notice linger  (1.6 s) best effort.
#   A  outcome linger (1.4 s) best effort and the weakest: it needs a delivered
#                             result, and Whisper returns nothing for silence,
#                             so an unattended run has no outcome to linger
#                             over. Expect INCONCLUSIVE unless a human speaks
#                             into it - the same limit that keeps S7's spoken
#                             run user-owned.
# plus a control that closes from a hidden dock, separating "this probe can see
# an artefact" from "there was one".
#
# Tray discovery happens before the clock starts; only a right-click and a menu
# read run inside the linger. Frames are captured raw and analysed afterwards,
# because per-frame analysis in PowerShell is slower than the transition.
#
# ASCII only inside string literals. These scripts carry no BOM, so Windows
# PowerShell reads them as ANSI and a multi-byte character inside a quoted
# string breaks the parse. Comments survive it.
param(
    [string]$Endpoint = "http://127.0.0.1:8080/inference",
    [ValidateSet("A", "B", "C", "control", "all")][string]$Scenario = "all"
)
$ErrorActionPreference = "Stop"

# `lib-tray.ps1` states its contract in its header: these four assemblies plus
# `$AE`/`$CT`/`$root` in the caller's scope. Its functions read those variables
# at call time, so omitting them fails inside the library rather than here -
# `Find-First` builds a `PropertyCondition` from a null `$AE::NameProperty`.
# `System.Windows.Forms` is what `Right-Click-At` needs for its cursor move.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
. (Join-Path $PSScriptRoot "lib-tray.ps1")

$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo "docs\plans\2026-08-13-local-desktop-dictation\artifacts\M3\teardown"
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
New-Item -ItemType Directory -Force -Path $out | Out-Null

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW")] public static extern bool SpiRect(uint a, uint p, ref RECT3 d, uint w);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT3 r);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint owner);
[DllImport("user32.dll", EntryPoint="GetWindowTextW", CharSet=CharSet.Unicode)] public static extern int GetText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", EntryPoint="GetClassNameW", CharSet=CharSet.Unicode)] public static extern int GetCls(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
public struct RECT3 { public int Left, Top, Right, Bottom; }
' -Name Wt -Namespace VT

function Hold-Down {
    [VT.Wt]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [VT.Wt]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [VT.Wt]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
}
function Hold-Up {
    [VT.Wt]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [VT.Wt]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [VT.Wt]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

# What state is the dock in: missing, hidden, parked or onscreen?
#
# The first version asked `FindWindowW($null, "Viby")` and always got 0, with a
# window titled exactly "Viby" visible on screen. PowerShell converts `$null` to
# an empty string for a `string` parameter, and FindWindow treats an empty class
# name as a class to match rather than as "any"; `[NullString]::Value` or an
# IntPtr overload would be required. So the guard never found the dock in any
# state and reported every one of them as hidden.
#
# EnumWindows over the process replaces it, and not only because it works: it
# tells the failures apart where a boolean collapsed them. Measured against the
# real binary, the dock is the `Tauri Window` titled `Viby`; the Options window
# shares that class under a different title.
#
# Parked is its own state on purpose. `bar::hide` moves the window to
# -32000,-32000 before `SW_HIDE`, so a dock caught mid-teardown can read visible
# while being nowhere the user can see.
function Get-DockState([uint32]$procId) {
    $script:TargetPid = $procId
    $script:DockRow = $null
    # The callback writes to script scope, never to the pipeline: a scriptblock
    # delegate invoked from native code has no pipeline to write into, so
    # `Write-Output` inside one goes nowhere.
    $cb = [VT.Wt+EnumProc]{
        param($h, $p)
        $owner = 0
        [void][VT.Wt]::GetWindowThreadProcessId($h, [ref]$owner)
        if ($owner -ne $script:TargetPid) { return $true }
        $c = New-Object System.Text.StringBuilder 256
        [void][VT.Wt]::GetCls($h, $c, 256)
        if ($c.ToString() -ne "Tauri Window") { return $true }
        $t = New-Object System.Text.StringBuilder 256
        [void][VT.Wt]::GetText($h, $t, 256)
        if ($t.ToString() -ne "Viby") { return $true }
        $r = New-Object VT.Wt+RECT3
        [void][VT.Wt]::GetWindowRect($h, [ref]$r)
        $script:DockRow = @{ Visible = [VT.Wt]::IsWindowVisible($h); Left = $r.Left }
        return $false
    }
    [void][VT.Wt]::EnumWindows($cb, [System.IntPtr]::Zero)
    if (-not $script:DockRow) { return "missing" }
    if (-not $script:DockRow.Visible) { return "hidden" }
    if ($script:DockRow.Left -le -30000) { return "parked" }
    return "onscreen"
}

# Whiteness per 16x16 cell over the whole frame, read through LockBits. A single
# 32bpp copy plus arithmetic is the only way this keeps up with a one-frame
# artefact; GetPixel over the same area costs seconds per frame.
function Cell-Map([System.Drawing.Bitmap]$bmp) {
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)

    $cols = [int][math]::Floor($bmp.Width / 16)
    $rows = [int][math]::Floor($bmp.Height / 16)
    $map = New-Object 'double[]' ($cols * $rows)
    for ($cy = 0; $cy -lt $rows; $cy++) {
        for ($cx = 0; $cx -lt $cols; $cx++) {
            $white = 0
            # Every 4th pixel in both axes: 16 samples per cell.
            for ($dy = 0; $dy -lt 16; $dy += 4) {
                $row = ($cy * 16 + $dy) * $data.Stride
                for ($dx = 0; $dx -lt 16; $dx += 4) {
                    $i = $row + ($cx * 16 + $dx) * 4
                    # Luma, not "all channels above 230". The artefact this
                    # milestone is chasing turned out to be a light blue classic
                    # caption at RGB 190,217,252 - R=190 fails a white test, so
                    # every PASS this probe reported before 2026-08-19 was blind
                    # to the very thing the user was seeing.
                    $luma = 0.114 * $bytes[$i] + 0.587 * $bytes[$i + 1] + 0.299 * $bytes[$i + 2]
                    if ($luma -gt 110) {
                        $white++
                    }
                }
            }
            $map[$cy * $cols + $cx] = $white / 16.0
        }
    }
    return @{ Map = $map; Cols = $cols; Rows = $rows }
}

# The worst TRANSIENT cell: white that is not there before and not there after.
#
# Scoring against the before-baseline alone does not work, and the first
# completed run showed exactly how it fails. That baseline is taken with the
# dock on screen and the tray menu open; Close removes both, so every later
# frame is "whiter" wherever dark pixels used to be. The run reported a steady
# 0.13 rising to a steady 0.25 at x=1624-1656 - the menu's own footprint, well
# clear of the dock at x=750-1170 - which is a description of the menu closing,
# not of an artefact.
#
# An artefact is transient by definition: present in one frame, absent before it
# and absent after everything settles. Taking the per-cell minimum of the two
# rises expresses that directly. A sustained change scores about zero against
# the final state; a one-frame flash scores high against both.
function Hot-Transient($cells, $baseline, $final, [int]$left, [int]$top) {
    $best = 0.0; $at = -1
    for ($i = 0; $i -lt $cells.Map.Length; $i++) {
        $vsBase = $cells.Map[$i] - $baseline.Map[$i]
        $vsFinal = $cells.Map[$i] - $final.Map[$i]
        $delta = [math]::Min($vsBase, $vsFinal)
        if ($delta -gt $best) { $best = $delta; $at = $i }
    }
    if ($at -lt 0) { return @{ Score = 0.0; X = 0; Y = 0 } }
    return @{
        Score = $best
        X     = $left + ($at % $cells.Cols) * 16 + 8
        Y     = $top + [int][math]::Floor($at / $cells.Cols) * 16 + 8
    }
}

function Write-Prefs([string]$Endpoint) {
    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    . (Join-Path $PSScriptRoot "lib-engine.ps1")
    Set-EnginePrefs $prefs.preferences $Endpoint
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    $prefs.preferences.microphone = $null
    # The confirmation step is opt in and off by default (D14); without the
    # reset an earlier run's flag leaks into this one and changes the flow.
    # `Add-Member -Force` rather than assignment, matching `smoke-bar.ps1`: a
    # store written before D14 has no such property, and `ConvertFrom-Json`
    # refuses to set one that is not there. Rust reads the same file without
    # complaint because `InsertionPrefs` is `#[serde(default)]`.
    $prefs.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
        -NotePropertyValue $false -Force
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))
}

# Finding the tray icon is the expensive half and it must happen OUTSIDE the
# linger being measured. `Send-WinB` alone sleeps 1200 ms, `Find-First` walks
# the whole UIA subtree from the desktop root, the hidden-icons branch adds
# 2000 ms, and `Get-TrayMenuItems` retries six times at 400 ms. Doing that after
# arming spends the entire budget of every linger.
#
# The coordinates are cached rather than the element, because a UIA element can
# go stale while the flow runs.
function Get-TrayIconPoint {
    $icon = $null
    for ($try = 0; $try -lt 8 -and -not $icon; $try++) {
        $icon = Find-TrayIcon
        if (-not $icon) { Start-Sleep -Milliseconds 800 }
    }
    if (-not $icon) { throw "no tray icon" }
    $rect = $icon.Current.BoundingRectangle
    return @{ X = [int]($rect.X + $rect.Width / 2); Y = [int]($rect.Y + $rect.Height / 2) }
}

# The fast half, safe inside a linger: right-click the cached point and read the
# menu. `Get-TrayMenuItems` has its own retry loop, so the wait is short here.
function Open-MenuFast {
    Right-Click-At $script:TrayPoint.X $script:TrayPoint.Y
    Start-Sleep -Milliseconds 250
    if (-not (Get-TrayMenuItems)) { throw "tray menu did not open" }
}

$results = [ordered]@{}

# One scenario: arm the state, invoke Close, capture the teardown, report the
# worst cell.
#
# The verdict goes into `$script:results` rather than out through `return`: a
# PowerShell function returns everything it did not capture, so the per-frame
# lines would join the return value and every scenario would read as a
# non-empty, therefore truthy, result.
function Invoke-Scenario([string]$name, [string]$label, [string]$engineEndpoint, [bool]$expectDock, [scriptblock]$arm) {
    $backup = [System.IO.File]::ReadAllBytes($storeFile)
    $viby = $null
    try {
        Write-Prefs $engineEndpoint
        if (Get-Process viby -ErrorAction SilentlyContinue) { throw "viby is running" }
        $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--force-renderer-accessibility"
        $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP "viby-teardown-webview"
        Start-Process $exe
        Start-Sleep -Seconds 6
        $viby = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $viby) { throw "viby did not start" }

        $work = New-Object VT.Wt+RECT3
        [void][VT.Wt]::SpiRect(0x30, 0, [ref]$work, 0)
        # The whole work area, not a strip: the reported artefacts sit at the
        # window's bottom-right corner and across its top, and only one of those
        # is anywhere near the bottom edge of the screen.
        $left = $work.Left
        $top = $work.Top
        $width = $work.Right - $work.Left
        $height = $work.Bottom - $work.Top

        # Expensive tray discovery first, while no clock is running.
        $script:TrayPoint = Get-TrayIconPoint

        # From here the linger is ticking, so arming is timed: an INCONCLUSIVE
        # run has to show whether the budget was the problem.
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        & $arm
        $armed = $clock.ElapsedMilliseconds

        # The premise check, at the one moment it has to hold: after arming and
        # before Close.
        $dock = Get-DockState $viby.Id
        $onScreen = $dock -eq "onscreen"
        Write-Output ("{0}: armed in {1} ms, dock {2}" -f $name, $armed, $dock)
        if ($onScreen -ne $expectDock) {
            $wanted = if ($expectDock) { "onscreen" } else { "not onscreen" }
            Write-Output ("{0}: INCONCLUSIVE - dock expected {1}, found {2}" -f $name, $wanted, $dock)
            # No cause is asserted. An earlier version blamed an expired linger
            # for a run that armed in 1462 ms against a 6 s clock, which its own
            # timing already disproved. The state name above is the fact.
            $script:results[$label] = $null
            return
        }

        # Baseline: the desktop as it stands with the dock in the state under
        # test and steady. An artefact is a rise over this, not over an empty
        # desktop, so the dock's own pixels do not count as one.
        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        $baseline = Cell-Map $bmp
        $bmp.Save((Join-Path $out "$name-baseline.png"))
        $bmp.Dispose()

        Invoke-TrayMenuItem "Close"

        # Raw capture first, analysis after. Measured on this machine: 18 ms per
        # full-work-area frame, one per display refresh, so 30 frames is about
        # 540 ms of continuous coverage from the click onward - ample for a
        # teardown, and fine enough not to step over a one-frame artefact.
        $frames = @()
        for ($i = 0; $i -lt 30; $i++) {
            $bmp = New-Object System.Drawing.Bitmap($width, $height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
            $g.Dispose()
            $frames += $bmp
        }

        # The settled desktop: process gone, dock gone, menu gone. This is the
        # other half of the transient test.
        Start-Sleep -Milliseconds 1200
        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        $final = Cell-Map $bmp
        $bmp.Save((Join-Path $out "$name-final.png"))
        $bmp.Dispose()

        if (-not $viby.HasExited) {
            Write-Output ("{0}: WARNING - the process is still alive after Close" -f $name)
        }

        $worst = 0.0
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $hot = Hot-Transient (Cell-Map $frames[$i]) $baseline $final $left $top
            Write-Output ("{0} frame {1:d2}: score={2:N2} at {3},{4}" -f $name, $i, $hot.Score, $hot.X, $hot.Y)
            if ($hot.Score -gt $worst) { $worst = $hot.Score }
            if ($hot.Score -gt 0.3) {
                $frames[$i].Save((Join-Path $out ("{0}-spike-{1:d2}-white-{2:N2}.png" -f $name, $i, $hot.Score)))
            }
        }
        $frames | ForEach-Object { $_.Dispose() }

        $verdict = if ($worst -gt 0.3) { "FAIL" } else { "PASS" }
        Write-Output ("{0}: {1} - worst cell rise {2:N2}" -f $name, $verdict, $worst)
        $script:results[$label] = ($verdict -eq "PASS")
    } finally {
        Hold-Up
        if ($viby -and -not $viby.HasExited) {
            Stop-Process -Id $viby.Id -Force -ErrorAction SilentlyContinue
        }
        [System.IO.File]::WriteAllBytes($storeFile, $backup)
        Remove-Item (Join-Path $env:TEMP "viby-teardown-webview") -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Scenario -in @("B", "all")) {
    # Error linger, 6 s: an unreadable model path fails the flow on the first
    # press. No speech, no model load, and the widest window of the three.
    Invoke-Scenario "B-error" "B error linger" "http://127.0.0.1:9/inference" $true {
        Hold-Down
        Start-Sleep -Milliseconds 400
        Hold-Up
        # Measured: Loading to Error takes about 30 ms on a path that does not
        # exist, so this only has to outlast the transition.
        Start-Sleep -Milliseconds 700
        Open-MenuFast
    }
}

if ($Scenario -in @("C", "all")) {
    # Notice linger, 1.6 s: discard mid-take, then press again while the worker
    # is still tearing down. The refusal shows the dock without changing state,
    # so `on_close_requested` still answers ExitClean.
    Invoke-Scenario "C-notice" "C notice linger" $Endpoint $true {
        Hold-Down
        Start-Sleep -Seconds 2
        Hold-Up
        Start-Sleep -Milliseconds 200
        Hold-Down
        Start-Sleep -Milliseconds 60
        Hold-Up
        Open-MenuFast
    }
}

if ($Scenario -in @("A", "all")) {
    # Outcome linger, 1.4 s, the tightest of the three and the one that needs a
    # delivered result. Silence produces none, so expect INCONCLUSIVE unattended.
    Invoke-Scenario "A-outcome" "A outcome linger" $Endpoint $true {
        Hold-Down
        Start-Sleep -Seconds 3
        Hold-Up
        Start-Sleep -Milliseconds 500
        Open-MenuFast
    }
}

if ($Scenario -in @("control", "all")) {
    # Control: Idle, dock hidden, nothing on screen to tear down. A FAIL here
    # means the probe is measuring something other than the dock.
    Invoke-Scenario "control" "control hidden dock" $Endpoint $false {
        Open-MenuFast
    }
}

Write-Output ""
Write-Output "=== teardown summary ==="
# Three outcomes, not two. $null is a run whose premise did not hold; it is
# reported as INCONCLUSIVE and exits non-zero, because a scenario that proved
# nothing must not read as a scenario that found nothing.
foreach ($k in $results.Keys) {
    $v = $results[$k]
    $verdict = if ($null -eq $v) { "INCONCLUSIVE" } elseif ($v) { "PASS" } else { "FAIL" }
    Write-Output ("{0}: {1}" -f $k, $verdict)
}
$bad = @($results.Values | Where-Object { $_ -ne $true }).Count
if ($bad -gt 0) { exit 1 }
