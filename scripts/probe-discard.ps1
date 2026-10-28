# Discard probe: what does the screen do when the dock's round X is clicked?
#
# This is the path the user reports, and the 2026-08-18 13:30 gate got it wrong.
# That gate recorded "real mouse click on X: 5/5 clean" and concluded the only
# reproduction left was "a path no user can take" because it needed UIA
# InvokePattern. The user then reproduced it with an ordinary mouse click, so
# the conclusion was wrong and this probe re-opens the question with a real
# click, a full-work-area capture, and a transient test.
#
# What the user describes is not a white flash: it is the classic, unthemed
# Win32 title bar - the Windows 95/98 non-client rendering - appearing for an
# instant. That matters for the instrument. A DWM compositor effect is invisible
# to BitBlt, which is the suspected blind spot of every probe here so far, but
# the classic non-client area is drawn by GDI and BitBlt does see it. So if this
# is what is happening, CopyFromScreen can catch it.
#
# The dock's own styles were measured and are clean: style=0x84000000
# (WS_POPUP|WS_CLIPSIBLINGS), ex=0x40008 (WS_EX_TOPMOST|WS_EX_APPWINDOW). No
# caption, no border. So this probe does not assume where the artefact comes
# from - it records the frames and reports where the change is.
#
# ASCII only inside string literals: no BOM, so a multi-byte character in a
# quoted string breaks the parse under Windows PowerShell.
param(
    [string]$ModelPath = "C:\openai-whisper\ggml-base-q5_1.bin",
    [int]$Repeats = 3,
    # Release the shortcut before clicking the X. The probe originally clicked
    # with Ctrl+Shift+Space still physically held, which no user does: a human
    # lets go of the keys and then reaches for the mouse. Modifiers change what
    # a click means to Chromium, so the two cases have to be told apart before
    # anything captured here can be called the user's artefact.
    [switch]$ReleaseFirst,
    # Click the level pill instead of the X. The pill is inert: it activates the
    # window and changes nothing else. If the caption bar appears here too, the
    # trigger is activation on its own and hiding the dock is irrelevant.
    [switch]$ClickPill
)
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
. (Join-Path $PSScriptRoot "lib-tray.ps1")

$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo "docs\plans\2026-08-13-local-desktop-dictation\artifacts\M3\discard"
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
New-Item -ItemType Directory -Force -Path $out | Out-Null

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);
[DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW")] public static extern bool SpiRect(uint a, uint p, ref RECT6 d, uint w);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint owner);
[DllImport("user32.dll", EntryPoint="GetClassNameW", CharSet=CharSet.Unicode)] public static extern int GetCls(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT6 r);
[DllImport("user32.dll", EntryPoint="GetWindowTextW", CharSet=CharSet.Unicode)] public static extern int GetText(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
public struct RECT6 { public int Left, Top, Right, Bottom; }
' -Name Wp -Namespace VP

# A real mouse click, declared here rather than borrowed from `lib-tray.ps1`.
# That library's left-click helper calls `[W.U32]::mouse_event`, but the `W.U32`
# type is only created as a side effect of the first right-click call - so it
# throws "No se encuentra el tipo [W.U32]" in any script that clicks with the
# left button before it has clicked with the right one.
function Click-At([int]$x, [int]$y) {
    [void][VP.Wp]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 60
    [VP.Wp]::mouse_event(0x0002, 0, 0, 0, 0)  # left down
    [VP.Wp]::mouse_event(0x0004, 0, 0, 0, 0)  # left up
}

function Hold-Down {
    [VP.Wp]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [VP.Wp]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [VP.Wp]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
}
function Hold-Up {
    [VP.Wp]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [VP.Wp]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [VP.Wp]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

# The dock's window handle: the `Tauri Window` titled `Viby` owned by this pid.
# Scoping the UIA search to it keeps another application's "Cancel" button out
# of the result.
function Get-DockHwnd([uint32]$procId) {
    $script:TargetPid = $procId
    $script:Hwnd = [System.IntPtr]::Zero
    $cb = [VP.Wp+EnumProc]{
        param($h, $p)
        $owner = 0
        [void][VP.Wp]::GetWindowThreadProcessId($h, [ref]$owner)
        if ($owner -ne $script:TargetPid) { return $true }
        $c = New-Object System.Text.StringBuilder 256
        [void][VP.Wp]::GetCls($h, $c, 256)
        if ($c.ToString() -ne "Tauri Window") { return $true }
        $t = New-Object System.Text.StringBuilder 256
        [void][VP.Wp]::GetText($h, $t, 256)
        if ($t.ToString() -ne "Viby") { return $true }
        $script:Hwnd = $h
        return $false
    }
    [void][VP.Wp]::EnumWindows($cb, [System.IntPtr]::Zero)
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
                    # Deliberately not "white only". A classic title bar is a
                    # saturated blue, and scoring only near-white would miss the
                    # very thing the user described. Luma over a mid threshold
                    # catches both a white flash and a bright chrome bar.
                    $luma = 0.114 * $bytes[$i] + 0.587 * $bytes[$i + 1] + 0.299 * $bytes[$i + 2]
                    if ($luma -gt 110) { $light++ }
                }
            }
            $map[$cy * $cols + $cx] = $light / 16.0
        }
    }
    return @{ Map = $map; Cols = $cols; Rows = $rows }
}

# The worst transient cell: brighter than before AND brighter than after.
function Hot-Transient($cells, $baseline, $final, [int]$left, [int]$top) {
    $best = 0.0; $at = -1
    for ($i = 0; $i -lt $cells.Map.Length; $i++) {
        $d = [math]::Min($cells.Map[$i] - $baseline.Map[$i], $cells.Map[$i] - $final.Map[$i])
        if ($d -gt $best) { $best = $d; $at = $i }
    }
    if ($at -lt 0) { return @{ Score = 0.0; X = 0; Y = 0 } }
    return @{
        Score = $best
        X     = $left + ($at % $cells.Cols) * 16 + 8
        Y     = $top + [int][math]::Floor($at / $cells.Cols) * 16 + 8
    }
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

$backup = [System.IO.File]::ReadAllBytes($storeFile)
$viby = $null
$worstOverall = 0.0
try {
    Write-Prefs
    if (Get-Process viby -ErrorAction SilentlyContinue) { throw "viby is running" }
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--force-renderer-accessibility"
    $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP "viby-discard-webview"
    Start-Process $exe
    Start-Sleep -Seconds 6
    $viby = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $viby) { throw "viby did not start" }

    $work = New-Object VP.Wp+RECT6
    [void][VP.Wp]::SpiRect(0x30, 0, [ref]$work, 0)
    $left = $work.Left; $top = $work.Top
    $width = $work.Right - $work.Left; $height = $work.Bottom - $work.Top

    for ($run = 1; $run -le $Repeats; $run++) {
        Write-Output ""
        Write-Output ("=== run {0} of {1} ===" -f $run, $Repeats)

        # Hold the shortcut: the dock comes up and stays up while recording, so
        # the X is on screen and clickable without racing a linger.
        Hold-Down
        Start-Sleep -Milliseconds 1800

        $hwnd = Get-DockHwnd $viby.Id
        if ($hwnd -eq [System.IntPtr]::Zero) { Hold-Up; throw "dock window not found" }
        $bar = $AE::FromHandle($hwnd)
        $cancel = $bar.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
            (New-Object System.Windows.Automation.AndCondition(
                (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Cancel")),
                (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))))
        if (-not $cancel) { Hold-Up; throw "the dock has no Cancel button while recording" }
        $r = $cancel.Current.BoundingRectangle
        $cx = [int]($r.X + $r.Width / 2)
        $cy = [int]($r.Y + $r.Height / 2)
        if ($ClickPill) {
            # Dead centre of the dock window: the level pill, which has no
            # handler. Activation without any state change.
            $wr = New-Object VP.Wp+RECT6
            [void][VP.Wp]::GetWindowRect((Get-DockHwnd $viby.Id), [ref]$wr)
            $cx = [int](($wr.Left + $wr.Right) / 2)
            $cy = [int](($wr.Top + $wr.Bottom) / 2)
        }
        Write-Output ("run {0}: clicking {1} at {2},{3}" -f $run, $(if ($ClickPill) { "the pill" } else { "the X" }), $cx, $cy)

        if ($ReleaseFirst) {
            # Processing keeps the dock and its X on screen after the release,
            # so the button is still there to click.
            Hold-Up
            Start-Sleep -Milliseconds 250
        }

        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        $baseline = Cell-Map $bmp
        $bmp.Save((Join-Path $out ("run{0}-baseline.png" -f $run)))
        $bmp.Dispose()

        # A real mouse click, not UIA Invoke. This is the distinction the
        # 13:30 gate drew, and the user's report says it does not hold.
        Click-At $cx $cy

        $frames = @()
        for ($i = 0; $i -lt 30; $i++) {
            $b = New-Object System.Drawing.Bitmap($width, $height)
            $gg = [System.Drawing.Graphics]::FromImage($b)
            $gg.CopyFromScreen($left, $top, 0, 0, $b.Size)
            $gg.Dispose()
            $frames += $b
        }
        Hold-Up

        Start-Sleep -Milliseconds 1500
        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        $final = Cell-Map $bmp
        $bmp.Save((Join-Path $out ("run{0}-final.png" -f $run)))
        $bmp.Dispose()

        $worst = 0.0
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $hot = Hot-Transient (Cell-Map $frames[$i]) $baseline $final $left $top
            if ($hot.Score -gt 0.2) {
                Write-Output ("run {0} frame {1:d2}: score={2:N2} at {3},{4}" -f $run, $i, $hot.Score, $hot.X, $hot.Y)
                $frames[$i].Save((Join-Path $out ("run{0}-spike-{1:d2}-{2:N2}.png" -f $run, $i, $hot.Score)))
            }
            if ($hot.Score -gt $worst) { $worst = $hot.Score }
        }
        $frames | ForEach-Object { $_.Dispose() }
        Write-Output ("run {0}: worst transient {1:N2}" -f $run, $worst)
        if ($worst -gt $worstOverall) { $worstOverall = $worst }
        Start-Sleep -Seconds 2
    }

    Write-Output ""
    Write-Output ("=== worst transient across {0} runs: {1:N2} ===" -f $Repeats, $worstOverall)
    if ($worstOverall -gt 0.2) {
        Write-Output "REPRODUCED - see the spike frames in artifacts/M3/discard/"
    } else {
        Write-Output "not reproduced by this instrument"
    }
} finally {
    Hold-Up
    if ($viby -and -not $viby.HasExited) { Stop-Process -Id $viby.Id -Force -ErrorAction SilentlyContinue }
    [System.IO.File]::WriteAllBytes($storeFile, $backup)
    Remove-Item (Join-Path $env:TEMP "viby-discard-webview") -Recurse -Force -ErrorAction SilentlyContinue
}
