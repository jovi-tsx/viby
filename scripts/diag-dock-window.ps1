# Why does `Dock-OnScreen` report the dock hidden 1.4 s after the shortcut?
#
# `probe-teardown.ps1` collapses three different failures into one `$false`:
# window not found, window found but not visible, and window found but parked
# off the virtual screen. It also blamed an expired linger for a run that armed
# in 1462 ms against a 6 s clock, which cannot be the cause. This script does
# not judge anything - it enumerates every top-level window the Viby process
# owns, before and after the shortcut, and prints what `FindWindowW` sees.
param([string]$ModelPath = "C:\viby-no-such-model.bin")
$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);
[DllImport("user32.dll", EntryPoint="FindWindowW", CharSet=CharSet.Unicode)] public static extern System.IntPtr FindWin(string cls, string title);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT4 r);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", EntryPoint="GetWindowTextW", CharSet=CharSet.Unicode)] public static extern int GetText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", EntryPoint="GetClassNameW", CharSet=CharSet.Unicode)] public static extern int GetCls(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern System.IntPtr GetLongPtr(System.IntPtr h, int i);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
public struct RECT4 { public int Left, Top, Right, Bottom; }
' -Name Wd -Namespace VD

function Hold-Down {
    [VD.Wd]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [VD.Wd]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [VD.Wd]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
}
function Hold-Up {
    [VD.Wd]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [VD.Wd]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [VD.Wd]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

function Show-Windows([uint32]$procId, [string]$when) {
    Write-Output ""
    Write-Output ("--- top-level windows of pid {0} : {1} ---" -f $procId, $when)
    # The callback must NOT write to the pipeline. A scriptblock delegate
    # invoked from native code has no pipeline to write into, so `Write-Output`
    # inside it goes nowhere - which is why the first run of this script printed
    # neither a window list nor "(none)". Collect, then print after EnumWindows
    # returns.
    $script:TargetPid = $procId
    $script:Rows = New-Object System.Collections.ArrayList
    $cb = [VD.Wd+EnumProc]{
        param($h, $p)
        $owner = 0
        [void][VD.Wd]::GetWindowThreadProcessId($h, [ref]$owner)
        if ($owner -ne $script:TargetPid) { return $true }
        $t = New-Object System.Text.StringBuilder 512
        [void][VD.Wd]::GetText($h, $t, 512)
        $c = New-Object System.Text.StringBuilder 512
        [void][VD.Wd]::GetCls($h, $c, 512)
        $r = New-Object VD.Wd+RECT4
        [void][VD.Wd]::GetWindowRect($h, [ref]$r)
        # GWL_STYLE -16, GWL_EXSTYLE -20
        [void]$script:Rows.Add(("  hwnd={0} vis={1} rect=({2},{3})-({4},{5}) style=0x{6:X} ex=0x{7:X} title='{8}' class='{9}'" -f `
            $h, [VD.Wd]::IsWindowVisible($h), $r.Left, $r.Top, $r.Right, $r.Bottom,
            [VD.Wd]::GetLongPtr($h, -16).ToInt64(), [VD.Wd]::GetLongPtr($h, -20).ToInt64(),
            $t.ToString(), $c.ToString()))
        return $true
    }
    [void][VD.Wd]::EnumWindows($cb, [System.IntPtr]::Zero)
    if ($script:Rows.Count -eq 0) { Write-Output "  (none)" }
    else { $script:Rows | ForEach-Object { Write-Output $_ } }

    $h = [VD.Wd]::FindWin($null, "Viby")
    if ($h -eq [System.IntPtr]::Zero) {
        Write-Output "  FindWindowW(null,'Viby') -> 0  <-- this is what Dock-OnScreen calls"
    } else {
        $r = New-Object VD.Wd+RECT4
        [void][VD.Wd]::GetWindowRect($h, [ref]$r)
        $owner = 0
        [void][VD.Wd]::GetWindowThreadProcessId($h, [ref]$owner)
        Write-Output ("  FindWindowW(null,'Viby') -> {0} pid={1} vis={2} left={3}" -f `
            $h, $owner, [VD.Wd]::IsWindowVisible($h), $r.Left)
    }
}

$backup = [System.IO.File]::ReadAllBytes($storeFile)
$viby = $null
try {
    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    $prefs.preferences.model.path = $ModelPath
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    $prefs.preferences.microphone = $null
    $prefs.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
        -NotePropertyValue $false -Force
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))

    if (Get-Process viby -ErrorAction SilentlyContinue) { throw "viby is running" }
    # The app's own log is the other half of the answer: it says whether the
    # shortcut arrived and which flow state followed.
    $env:RUST_LOG = "viby=info"
    # `tracing_subscriber::fmt()` writes to stdout by default, so both streams
    # are captured and both are printed; guessing wrong here would look like an
    # app that logged nothing.
    $log = Join-Path $env:TEMP "viby-diag.err"
    $outLog = Join-Path $env:TEMP "viby-diag.out"
    Start-Process $exe -RedirectStandardError $log -RedirectStandardOutput $outLog
    Start-Sleep -Seconds 6
    $viby = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $viby) { throw "viby did not start" }

    Show-Windows $viby.Id "at rest, before the shortcut"

    Hold-Down
    Start-Sleep -Milliseconds 400
    Hold-Up
    Start-Sleep -Milliseconds 700
    Show-Windows $viby.Id "1.1 s after the press (dock should be up, flow in Error)"

    Start-Sleep -Seconds 7
    Show-Windows $viby.Id "8 s after the press (error linger expired, dock should be down)"

    Write-Output ""
    Write-Output "--- app log (stdout) ---"
    if (Test-Path $outLog) { Get-Content $outLog -Tail 40 } else { Write-Output "  (none)" }
    Write-Output "--- app log (stderr) ---"
    if (Test-Path $log) { Get-Content $log -Tail 40 } else { Write-Output "  (none)" }
} finally {
    Hold-Up
    if ($viby -and -not $viby.HasExited) { Stop-Process -Id $viby.Id -Force -ErrorAction SilentlyContinue }
    [System.IO.File]::WriteAllBytes($storeFile, $backup)
}
