# M2 production final-result smoke: one operator-spoken hold-to-talk run
# through the real app (global shortcut -> FlowController -> FlowEvent::Final).
# Nothing here bypasses the production flow.
#
# Evidence channel: the app's own tracing log. `flow final` carries only the
# character count, the elapsed final-inference time, and whether the webview
# event was delivered; recognized text is never logged (R5 zero retention).
#
# Usage from WSL, once per model under measurement:
#   powershell.exe -ExecutionPolicy Bypass -File scripts\smoke-final-result.ps1 `
#       -ModelPath C:\openai-whisper\ggml-base-q5_1.bin -Variant base-q5_1

param(
    [Parameter(Mandatory = $true)][string]$ModelPath,
    [Parameter(Mandatory = $true)][string]$Variant,
    [int]$ProcessingTimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
$storeExisted = Test-Path $storeFile
$storeBackup = if ($storeExisted) { [System.IO.File]::ReadAllBytes($storeFile) } else { $null }
$logFile = Join-Path $env:TEMP "viby-final-trace.log"
$errFile = Join-Path $env:TEMP "viby-final-trace.err"

if (-not (Test-Path $ModelPath)) { throw "model file not found: $ModelPath" }
if (-not (Test-Path $exe)) { throw "release executable not found: $exe (run cargo tauri build)" }

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

function Assert-Order($states, $expected, $label) {
    $position = 0
    foreach ($want in $expected) {
        $found = $false
        while ($position -lt $states.Count) {
            if ($states[$position] -eq $want) { $found = $true; $position++; break }
            $position++
        }
        if (-not $found) { throw "$label missing '$want' in: $($states -join ' -> ')" }
    }
}

try {
    if (Get-Process viby -ErrorAction SilentlyContinue) {
        throw "another Viby process is running; smoke refuses to terminate it"
    }
    if (-not $storeExisted) { throw "no preferences store at $storeFile; run Viby once first" }

    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    $prefs.preferences.model.path = $ModelPath
    $prefs.preferences.model.variant = $Variant
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    # serde_json rejects a BOM; write strict UTF-8
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))

    Remove-Item $logFile, $errFile -Force -ErrorAction SilentlyContinue
    # cmd redirection flushes eagerly; -RedirectStandardOutput only on exit.
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList ('/c ""{0}" > "{1}" 2> "{2}""' -f $exe, $logFile, $errFile) | Out-Null
    Start-Sleep -Seconds 5
    # The preflight refuses to run beside a pre-existing instance, so this is
    # our process. Own the PID: cleanup must never kill a user's instance.
    $viby = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $viby) { throw "viby.exe did not start" }

    Write-Output "model: $Variant ($ModelPath)"
    Write-Output ""
    Write-Output "OPERATOR: hold Ctrl+Shift+Space, speak the reference sentence,"
    Write-Output "          then release. Do not close this window."
    Write-Output ""

    $deadline = (Get-Date).AddSeconds($ProcessingTimeoutSeconds)
    $finalLine = $null
    while (-not $finalLine -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $finalLine = Get-CleanLog | Where-Object { $_ -match 'flow final' } | Select-Object -First 1
        if ($viby.HasExited) {
            throw "viby.exe exited before delivering a final result"
        }
    }
    if (-not $finalLine) { throw "no final result within $ProcessingTimeoutSeconds s" }

    $connections = Get-NetTCPConnection -OwningProcess $viby.Id -ErrorAction SilentlyContinue
    if ($connections) { throw "viby.exe held TCP connections during the flow" }
    Write-Output "network-observation: NO TCP CONNECTIONS"

    # The Idle transition after the final proves the flow returned to rest.
    Start-Sleep -Seconds 2
    $states = Get-FlowStates
    Write-Output ("state-sequence: " + ($states -join " -> "))
    Assert-Order $states @("Loading", "Recording", "Processing", "Idle") "final run"

    if ($finalLine -notmatch 'chars=(\d+)') { throw "final line without chars: $finalLine" }
    $chars = [int]$Matches[1]
    if ($finalLine -notmatch 'seconds=([0-9.]+)') { throw "final line without seconds: $finalLine" }
    $seconds = [double]$Matches[1]
    if ($chars -le 0) { throw "final result was empty; the production path delivered no text" }
    # `delivered` is the emit result itself: the run fails if the final event
    # never reached the webview, so the log cannot stand in for delivery.
    if ($finalLine -notmatch 'delivered=true') {
        throw "final result was not delivered to the webview: $finalLine"
    }

    Write-Output "FINAL_CHARS=$chars"
    Write-Output ("FINAL_SECONDS={0:N2}" -f $seconds)
    Write-Output "final-result-delivered: PASS ($Variant)"
    Write-Output "`nSMOKE PASS"
} finally {
    if ($viby -and -not $viby.HasExited) {
        Stop-Process -Id $viby.Id -Force -ErrorAction SilentlyContinue
        $viby.WaitForExit(5000) | Out-Null
    }
    if ($storeExisted) { [System.IO.File]::WriteAllBytes($storeFile, $storeBackup) }
    Remove-Item (Join-Path (Split-Path $storeFile) "preferences.bak") -Force -ErrorAction SilentlyContinue
}
