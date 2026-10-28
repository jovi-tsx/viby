# Measurement harness for the caption-bar artefact.
#
# `probe-discard.ps1` proved the artefact exists. It is not fit to judge a
# remedy: it runs every repeat inside one app session, and on 2026-08-19 the
# same build scored 1/6 on one sample and 7/8 on another. Run-to-run variance
# at n=6 was larger than the effect, so every "this fixed it" reading that day
# was noise.
#
# Protocol, fixed before any run:
#   unit        one discard cycle with a FRESH app process. Repeats inside a
#               session are not independent - the first discard of a session
#               behaved differently from the rest - so each measurement restarts.
#   hit         transient score > 0.50. The artefact scores 1.00 when present
#               and measured noise never exceeded 0.25, so nothing lands near
#               the line.
#   n           20 per condition.
#   decision    0/20 candidate fix; 1-3/20 partial mitigation, not a fix;
#               4 or more, no effect.
#
# Results append to a CSV so conditions accumulate across invocations.
#
# ASCII only inside string literals: these scripts carry no BOM.
param(
    [Parameter(Mandatory = $true)][string]$Label,
    [int]$Sessions = 10,
    [string]$ModelPath = "C:\openai-whisper\ggml-base-q5_1.bin"
)
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
. (Join-Path $PSScriptRoot "lib-tray.ps1")

$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo "docs\plans\2026-08-13-local-desktop-dictation\artifacts\M3\experiment"
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
$csv = Join-Path $out "results.csv"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (-not (Test-Path $csv)) { "label,session,score,hit" | Set-Content $csv -Encoding ASCII }

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);
[DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW")] public static extern bool SpiRect(uint a, uint p, ref RECT8 d, uint w);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint owner);
[DllImport("user32.dll", EntryPoint="GetClassNameW", CharSet=CharSet.Unicode)] public static extern int GetCls(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", EntryPoint="GetWindowTextW", CharSet=CharSet.Unicode)] public static extern int GetText(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
public struct RECT8 { public int Left, Top, Right, Bottom; }
' -Name We -Namespace VE

function Click-At([int]$x, [int]$y) {
    [void][VE.We]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 60
    [VE.We]::mouse_event(0x0002, 0, 0, 0, 0)
    [VE.We]::mouse_event(0x0004, 0, 0, 0, 0)
}
function Hold-Down {
    [VE.We]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [VE.We]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [VE.We]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
}
function Hold-Up {
    [VE.We]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [VE.We]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [VE.We]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

function Get-DockHwnd([uint32]$procId) {
    $script:TargetPid = $procId
    $script:Hwnd = [System.IntPtr]::Zero
    $cb = [VE.We+EnumProc]{
        param($h, $p)
        $owner = 0
        [void][VE.We]::GetWindowThreadProcessId($h, [ref]$owner)
        if ($owner -ne $script:TargetPid) { return $true }
        $c = New-Object System.Text.StringBuilder 256
        [void][VE.We]::GetCls($h, $c, 256)
        if ($c.ToString() -ne "Tauri Window") { return $true }
        $t = New-Object System.Text.StringBuilder 256
        [void][VE.We]::GetText($h, $t, 256)
        if ($t.ToString() -ne "Viby") { return $true }
        $script:Hwnd = $h
        return $false
    }
    [void][VE.We]::EnumWindows($cb, [System.IntPtr]::Zero)
    return $script:Hwnd
}

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
            $light = 0
            for ($dy = 0; $dy -lt 16; $dy += 4) {
                $row = ($cy * 16 + $dy) * $data.Stride
                for ($dx = 0; $dx -lt 16; $dx += 4) {
                    $i = $row + ($cx * 16 + $dx) * 4
                    $luma = 0.114 * $bytes[$i] + 0.587 * $bytes[$i + 1] + 0.299 * $bytes[$i + 2]
                    if ($luma -gt 110) { $light++ }
                }
            }
            $map[$cy * $cols + $cx] = $light / 16.0
        }
    }
    return @{ Map = $map; Cols = $cols; Rows = $rows }
}

function Hot-Transient($cells, $baseline, $final) {
    $best = 0.0
    for ($i = 0; $i -lt $cells.Map.Length; $i++) {
        $d = [math]::Min($cells.Map[$i] - $baseline.Map[$i], $cells.Map[$i] - $final.Map[$i])
        if ($d -gt $best) { $best = $d }
    }
    return $best
}

function Write-Prefs {
    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    $prefs.preferences.model.path = $ModelPath
    $prefs.preferences.model.variant = "base-q5_1"
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    $prefs.preferences.microphone = $null
    $prefs.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
        -NotePropertyValue $false -Force
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))
}

# One measurement: fresh process, one discard, score, kill. Returns $null when
# the session could not be set up, which is recorded as such rather than as a
# clean run - a session that did not happen is not evidence of absence.
function Measure-Session([int]$n) {
    $script:FailReason = "unknown"
    $viby = $null
    try {
        # Every Get-Process here carries -ErrorAction: with the script-level
        # preference set to Stop, a name that matches nothing is a terminating
        # error, and one stray exit between the check and the kill would take
        # down the whole batch.
        $stale = @(Get-Process viby -ErrorAction SilentlyContinue)
        if ($stale.Count -gt 0) {
            $stale | Stop-Process -Force -ErrorAction SilentlyContinue
            # The killed process does not release the global shortcut instantly.
            # Restarting too soon leaves the new instance unable to register it,
            # the press does nothing, no dock appears, and the session is scored
            # as a setup failure - which is how a batch reached 7 failures in 11.
            Start-Sleep -Milliseconds 2000
        }
        $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--force-renderer-accessibility"
        $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP "viby-exp-webview"
        Start-Process $exe
        Start-Sleep -Seconds 6
        $viby = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $viby) { $script:FailReason = "process did not start"; return $null }

        $work = New-Object VE.We+RECT8
        [void][VE.We]::SpiRect(0x30, 0, [ref]$work, 0)
        $left = $work.Left; $top = $work.Top
        $width = $work.Right - $work.Left; $height = $work.Bottom - $work.Top

        # Two attempts at the shortcut before calling it a failed session: the
        # first press after a restart is the one that loses to a shortcut still
        # held by the previous process.
        $hwnd = [System.IntPtr]::Zero
        for ($try = 0; $try -lt 2 -and $hwnd -eq [System.IntPtr]::Zero; $try++) {
            Hold-Down
            Start-Sleep -Milliseconds 1800
            $hwnd = Get-DockHwnd $viby.Id
            if ($hwnd -eq [System.IntPtr]::Zero) {
                Hold-Up
                Start-Sleep -Milliseconds 1200
            }
        }
        if ($hwnd -eq [System.IntPtr]::Zero) {
            $script:FailReason = "dock never appeared - the shortcut did not start a flow"
            Hold-Up; return $null
        }
        # Poll for the button rather than asking once. The dock is on screen
        # well before WebView2 has published its accessibility tree, and a
        # single FindFirst turned 7 sessions out of 11 into setup failures.
        # Waiting longer does not distort the measurement: the artefact is
        # triggered by the click, not by when the button is located.
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Cancel")),
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
        $cancel = $null
        $wait = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $cancel -and $wait.ElapsedMilliseconds -lt 4000) {
            $bar = $AE::FromHandle($hwnd)
            $cancel = $bar.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $cond)
            if (-not $cancel) { Start-Sleep -Milliseconds 200 }
        }
        if (-not $cancel) {
            $script:FailReason = "dock is up but UIA sees no Cancel button"
            Hold-Up; return $null
        }
        $r = $cancel.Current.BoundingRectangle
        $cx = [int]($r.X + $r.Width / 2); $cy = [int]($r.Y + $r.Height / 2)

        # The user lets go of the keys before reaching for the mouse.
        Hold-Up
        Start-Sleep -Milliseconds 250

        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        $baseline = Cell-Map $bmp
        $bmp.Dispose()

        Click-At $cx $cy

        $frames = @()
        for ($i = 0; $i -lt 30; $i++) {
            $b = New-Object System.Drawing.Bitmap($width, $height)
            $gg = [System.Drawing.Graphics]::FromImage($b)
            $gg.CopyFromScreen($left, $top, 0, 0, $b.Size)
            $gg.Dispose()
            $frames += $b
        }

        Start-Sleep -Milliseconds 1200
        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        $final = Cell-Map $bmp
        $bmp.Dispose()

        $worst = 0.0
        $worstIdx = -1
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $sc = Hot-Transient (Cell-Map $frames[$i]) $baseline $final
            if ($sc -gt $worst) { $worst = $sc; $worstIdx = $i }
        }
        # Keep one frame per hit, for the record; clean runs leave no files.
        if ($worst -gt 0.5 -and $worstIdx -ge 0) {
            $frames[$worstIdx].Save((Join-Path $out ("{0}-s{1:d2}-{2:N2}.png" -f $Label, $n, $worst)))
        }
        $frames | ForEach-Object { $_.Dispose() }
        return $worst
    } finally {
        Hold-Up
        if ($viby -and -not $viby.HasExited) {
            Stop-Process -Id $viby.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

$backup = [System.IO.File]::ReadAllBytes($storeFile)
try {
    Write-Prefs
    $hits = 0; $done = 0; $failed = 0
    for ($n = 1; $n -le $Sessions; $n++) {
        # One bad session must not cost the batch: the point of n=20 is lost if
        # a transient failure at session 7 discards the six before it.
        $score = $null
        try {
            $score = Measure-Session $n
        } catch {
            Write-Output ("{0} session {1,2}: ERROR {2}" -f $Label, $n, $_.Exception.Message)
        }
        if ($null -eq $score) {
            $failed++
            Write-Output ("{0} session {1,2}: SETUP FAILED - {2}" -f $Label, $n, $script:FailReason)
            continue
        }
        $done++
        $hit = $score -gt 0.5
        if ($hit) { $hits++ }
        ("{0},{1},{2},{3}" -f $Label, $n, $score.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture), $(if ($hit) { 1 } else { 0 })) |
            Add-Content $csv -Encoding ASCII
        Write-Output ("{0} session {1,2}: score={2:N2} {3}" -f $Label, $n, $score, $(if ($hit) { "HIT" } else { "clean" }))
    }
    Write-Output ""
    Write-Output ("{0}: {1}/{2} hits, {3} setup failures" -f $Label, $hits, $done, $failed)
} finally {
    Hold-Up
    Get-Process viby -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllBytes($storeFile, $backup)
    Remove-Item (Join-Path $env:TEMP "viby-exp-webview") -Recurse -Force -ErrorAction SilentlyContinue
}
