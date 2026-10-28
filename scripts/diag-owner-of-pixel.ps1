# A classic Win32 title bar reading "Viby" is painted across the top of the dock
# for about two frames after the round X is clicked. `probe-discard.ps1` caught
# it 3/3 at score 1.00, position 776,920, inside a window measured at rest as
# style=0x84000000 (WS_POPUP|WS_CLIPSIBLINGS) with no caption bit at all.
#
# A window with no WS_CAPTION has no title bar to paint, so something is putting
# one back. This script does not guess which: it polls the window's style,
# extended style and rect as fast as PowerShell can from just before the click
# until well after, and prints every transition. Whatever re-adds WS_CAPTION -
# or WS_DLGFRAME, or WS_BORDER - shows up as a change in the log.
#
# ASCII only inside string literals.
param([string]$ModelPath = "C:\openai-whisper\ggml-base-q5_1.bin")
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
. (Join-Path $PSScriptRoot "lib-tray.ps1")

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);
[DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint owner);
[DllImport("user32.dll", EntryPoint="GetClassNameW", CharSet=CharSet.Unicode)] public static extern int GetCls(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", EntryPoint="GetWindowTextW", CharSet=CharSet.Unicode)] public static extern int GetText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern System.IntPtr GetLongPtr(System.IntPtr h, int i);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT7 r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr GetParent(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint f);
public struct POINT { public int X, Y; }
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
public struct RECT7 { public int Left, Top, Right, Bottom; }
' -Name Wf -Namespace VS

function Click-At([int]$x, [int]$y) {
    [void][VS.Wf]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 60
    [VS.Wf]::mouse_event(0x0002, 0, 0, 0, 0)
    [VS.Wf]::mouse_event(0x0004, 0, 0, 0, 0)
}
function Hold-Down {
    [VS.Wf]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [VS.Wf]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [VS.Wf]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
}
function Hold-Up {
    [VS.Wf]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [VS.Wf]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [VS.Wf]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

function Get-DockHwnd([uint32]$procId) {
    $script:TargetPid = $procId
    $script:Hwnd = [System.IntPtr]::Zero
    $cb = [VS.Wf+EnumProc]{
        param($h, $p)
        $owner = 0
        [void][VS.Wf]::GetWindowThreadProcessId($h, [ref]$owner)
        if ($owner -ne $script:TargetPid) { return $true }
        $c = New-Object System.Text.StringBuilder 256
        [void][VS.Wf]::GetCls($h, $c, 256)
        if ($c.ToString() -ne "Tauri Window") { return $true }
        $t = New-Object System.Text.StringBuilder 256
        [void][VS.Wf]::GetText($h, $t, 256)
        if ($t.ToString() -ne "Viby") { return $true }
        $script:Hwnd = $h
        return $false
    }
    [void][VS.Wf]::EnumWindows($cb, [System.IntPtr]::Zero)
    return $script:Hwnd
}

# Names for the style bits that can produce a frame, so the log reads as
# something other than hex.
function Describe-Style([int64]$s) {
    $bits = @()
    if ($s -band 0x00C00000) { $bits += "WS_CAPTION" }
    if ($s -band 0x00400000) { $bits += "WS_DLGFRAME" }
    if ($s -band 0x00800000) { $bits += "WS_BORDER" }
    if ($s -band 0x00080000) { $bits += "WS_SYSMENU" }
    if ($s -band 0x00040000) { $bits += "WS_THICKFRAME" }
    if ($s -band 0x80000000) { $bits += "WS_POPUP" }
    if ($s -band 0x10000000) { $bits += "WS_VISIBLE" }
    if ($s -band 0x04000000) { $bits += "WS_CLIPSIBLINGS" }
    if ($bits.Count -eq 0) { return "(none)" }
    return ($bits -join "|")
}
function Describe-Ex([int64]$s) {
    $bits = @()
    if ($s -band 0x00000100) { $bits += "WS_EX_WINDOWEDGE" }
    if ($s -band 0x00000200) { $bits += "WS_EX_CLIENTEDGE" }
    if ($s -band 0x00000001) { $bits += "WS_EX_DLGMODALFRAME" }
    if ($s -band 0x00000008) { $bits += "WS_EX_TOPMOST" }
    if ($s -band 0x00040000) { $bits += "WS_EX_APPWINDOW" }
    if ($s -band 0x00000080) { $bits += "WS_EX_TOOLWINDOW" }
    if ($s -band 0x00080000) { $bits += "WS_EX_LAYERED" }
    if ($bits.Count -eq 0) { return "(none)" }
    return ($bits -join "|")
}

function Snapshot([System.IntPtr]$h) {
    $r = New-Object VS.Wf+RECT7
    [void][VS.Wf]::GetWindowRect($h, [ref]$r)
    return [pscustomobject]@{
        Style = [VS.Wf]::GetLongPtr($h, -16).ToInt64()
        Ex    = [VS.Wf]::GetLongPtr($h, -20).ToInt64()
        Vis   = [VS.Wf]::IsWindowVisible($h)
        Rect  = ("{0},{1}-{2},{3}" -f $r.Left, $r.Top, $r.Right, $r.Bottom)
    }
}

$backup = [System.IO.File]::ReadAllBytes($storeFile)
$viby = $null
try {
    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    $prefs.preferences.model.path = $ModelPath
    $prefs.preferences.model.variant = "base-q5_1"
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    $prefs.preferences.microphone = $null
    $prefs.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
        -NotePropertyValue $false -Force
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))

    if (Get-Process viby -ErrorAction SilentlyContinue) { throw "viby is running" }
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--force-renderer-accessibility"
    $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP "viby-style-webview"
    Start-Process $exe
    Start-Sleep -Seconds 6
    $viby = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $viby) { throw "viby did not start" }

    Hold-Down
    Start-Sleep -Milliseconds 1800
    $hwnd = Get-DockHwnd $viby.Id
    if ($hwnd -eq [System.IntPtr]::Zero) { Hold-Up; throw "dock window not found" }

    $bar = $AE::FromHandle($hwnd)
    $cancel = $bar.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Cancel")),
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))))
    if (-not $cancel) { Hold-Up; throw "no Cancel button" }
    $r = $cancel.Current.BoundingRectangle
    $cx = [int]($r.X + $r.Width / 2); $cy = [int]($r.Y + $r.Height / 2)

    # Ask Windows who owns the pixel the blue bar occupies, as fast as possible,
    # from just before the click until well after. A child window never appears
    # in EnumWindows, so the earlier census could not have seen one.
    function Describe-Hwnd([System.IntPtr]$h) {
        if ($h -eq [System.IntPtr]::Zero) { return "hwnd=0" }
        $owner = 0
        [void][VS.Wf]::GetWindowThreadProcessId($h, [ref]$owner)
        $c = New-Object System.Text.StringBuilder 256
        [void][VS.Wf]::GetCls($h, $c, 256)
        $t = New-Object System.Text.StringBuilder 256
        [void][VS.Wf]::GetText($h, $t, 256)
        $r = New-Object VS.Wf+RECT7
        [void][VS.Wf]::GetWindowRect($h, [ref]$r)
        $parent = [VS.Wf]::GetParent($h)
        # GA_ROOT = 2
        $rootw = [VS.Wf]::GetAncestor($h, 2)
        return ("hwnd={0} pid={1} class='{2}' title='{3}' style=0x{4:X} rect=({5},{6})-({7},{8}) parent={9} root={10}" -f `
            $h, $owner, $c.ToString(), $t.ToString(), [VS.Wf]::GetLongPtr($h, -16).ToInt64(),
            $r.Left, $r.Top, $r.Right, $r.Bottom, $parent, $rootw)
    }

    $pt = New-Object VS.Wf+POINT
    $pt.X = 900; $pt.Y = 918
    Write-Output ("probing pixel {0},{1} - the middle of the blue bar" -f $pt.X, $pt.Y)
    Write-Output ("before click: " + (Describe-Hwnd ([VS.Wf]::WindowFromPoint($pt))))
    Write-Output ""

    Click-At $cx $cy
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = ""
    $n = 0
    while ($clock.ElapsedMilliseconds -lt 500) {
        $h = [VS.Wf]::WindowFromPoint($pt)
        $d = Describe-Hwnd $h
        $n++
        if ($d -ne $prev) {
            Write-Output ("+{0,4} ms: {1}" -f $clock.ElapsedMilliseconds, $d)
            $prev = $d
        }
    }
    Write-Output ("polled {0} samples" -f $n)

    Hold-Up
} finally {
    Hold-Up
    if ($viby -and -not $viby.HasExited) { Stop-Process -Id $viby.Id -Force -ErrorAction SilentlyContinue }
    [System.IO.File]::WriteAllBytes($storeFile, $backup)
    Remove-Item (Join-Path $env:TEMP "viby-style-webview") -Recurse -Force -ErrorAction SilentlyContinue
}
