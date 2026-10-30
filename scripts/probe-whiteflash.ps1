# One-off probe v4: full bottom strip, ~10ms cadence, save the top frames by
# localized whiteness around the cancel transition.
param([string]$Endpoint = "http://127.0.0.1:8080/inference")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
. (Join-Path $PSScriptRoot "lib-tray.ps1")

$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo "docs\plans\2026-08-13-local-desktop-dictation\artifacts\M3\whiteflash"
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
$backup = [System.IO.File]::ReadAllBytes($storeFile)

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW")] public static extern bool SpiRect(uint a, uint p, ref RECT2 d, uint w);
public struct RECT2 { public int Left, Top, Right, Bottom; }
' -Name Wq -Namespace VQ

function Hold-Down {
    [VQ.Wq]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [VQ.Wq]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [VQ.Wq]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
}
function Hold-Up {
    [VQ.Wq]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [VQ.Wq]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [VQ.Wq]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

# Block map: whiteness of each 24x24 block on a coarse grid.
function Block-Map($bmp) {
    $map = @{}
    for ($x0 = 0; $x0 -le $bmp.Width - 24; $x0 += 8) {
        for ($y0 = 0; $y0 -le $bmp.Height - 24; $y0 += 8) {
            $white = 0
            for ($x = $x0; $x -lt $x0 + 24; $x += 4) {
                for ($y = $y0; $y -lt $y0 + 24; $y += 4) {
                    $px = $bmp.GetPixel($x, $y)
                    if ($px.R -gt 230 -and $px.G -gt 230 -and $px.B -gt 230) { $white++ }
                }
            }
            $map["$x0,$y0"] = [double]$white / 36.0
        }
    }
    return $map
}

# Biggest per-block jump over the baseline, and where.
function Hot-Delta($bmp, $baseline, [int]$left, [int]$top) {
    $map = Block-Map $bmp
    $best = 0.0; $key = $null
    foreach ($k in $map.Keys) {
        $delta = $map[$k] - $baseline[$k]
        if ($delta -gt $best) { $best = $delta; $key = $k }
    }
    $xy = $key -split ","
    return @{ Score = $best; X = $left + [int]$xy[0] + 12; Y = $top + [int]$xy[1] + 12 }
}

$viby = $null
try {
    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    . (Join-Path $PSScriptRoot "lib-engine.ps1")
    Set-EnginePrefs $prefs.preferences $Endpoint
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    $prefs.preferences.microphone = $null
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))

    if (Get-Process viby -ErrorAction SilentlyContinue) { throw "viby is running" }
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--force-renderer-accessibility"
    $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP "viby-probe-webview"
    Start-Process $exe
    Start-Sleep -Seconds 6
    $viby = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $viby) { throw "viby did not start" }

    $work = New-Object VQ.Wq+RECT2
    [void][VQ.Wq]::SpiRect(0x30, 0, [ref]$work, 0)
    $width = $work.Right - $work.Left
    $height = 260
    $left = $work.Left
    $top = $work.Bottom - $height

    # Hold, then end the flow through the tray's Close: the process exits and
    # the window is destroyed, not hidden — a different teardown entirely.
    Hold-Down
    Start-Sleep -Seconds 2
    $icon = $null
    for ($try = 0; $try -lt 8 -and -not $icon; $try++) {
        $icon = Find-TrayIcon
        if (-not $icon) { Start-Sleep -Milliseconds 800 }
    }
    if (-not $icon) { throw "no tray icon" }
    $iconRect = $icon.Current.BoundingRectangle
    Right-Click-At ([int]($iconRect.X + $iconRect.Width / 2)) ([int]($iconRect.Y + $iconRect.Height / 2))
    Start-Sleep -Milliseconds 1200
    Get-TrayMenuItems | Out-Null
    Invoke-TrayMenuItem "Close"
    Hold-Up

    # Baseline map with the dock fully drawn and steady.
    $bmp = New-Object System.Drawing.Bitmap($width, $height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
    $g.Dispose()
    $baseline = Block-Map $bmp
    $bmp.Dispose()

    $records = @()
    for ($i = 0; $i -lt 120; $i++) {
        if ($i -eq 3) {
            # Wait for the final transcription before capturing the hide.
        }
        $bmp = New-Object System.Drawing.Bitmap($width, $height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        $hot = Hot-Delta $bmp $baseline $left $top
        $records += [pscustomobject]@{ Frame = $i; Score = $hot.Score; X = $hot.X; Y = $hot.Y; Bmp = $bmp }
        if ($i -le 10) {
            $bmp.Save((Join-Path $out ("seq-{0:d3}.png" -f $i)))
        }
    }
    $records | Sort-Object Frame | ForEach-Object {
        Write-Output ("frame {0:d3}: score={1:N2} at {2},{3}" -f $_.Frame, $_.Score, $_.X, $_.Y)
    }
    $records | Where-Object { $_.Score -gt 0.3 -and $_.Frame -lt 12 } | ForEach-Object {
        $_.Bmp.Save((Join-Path $out ("v4-spike-{0:d3}-white-{1:N2}.png" -f $_.Frame, $_.Score)))
    }
    $records | ForEach-Object { $_.Bmp.Dispose() }
} finally {
    Hold-Up
    if ($viby -and -not $viby.HasExited) { Stop-Process -Id $viby.Id -Force -ErrorAction SilentlyContinue }
    [System.IO.File]::WriteAllBytes($storeFile, $backup)
    Remove-Item (Join-Path $env:TEMP "viby-probe-webview") -Recurse -Force -ErrorAction SilentlyContinue
}
