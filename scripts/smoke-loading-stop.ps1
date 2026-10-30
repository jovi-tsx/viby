# Lifecycle smoke: hold-to-talk state machine against the user's engine (D23).
# Pass a slow model with -StartEngine -EngineModel ...ggml-small.bin to widen
# the Processing window run D needs.
# Evidence channel: the app's own tracing log (`flow state` lines), captured
# via redirected stdout — immune to UIA sampling races.
# Run A (250 ms hold): orders Loading before Processing. Before D23 this run
# released during the model load and asserted no Recording; there is no model
# load any more, Loading only spans the microphone opening, and the same
# state-lock decision in flow.rs still orders a release there before any
# Recording.
# Run B (1.5 s hold): must order Loading -> Recording -> Processing -> Idle
# and log a delivered final; this is the mandatory positive control that keeps
# the Close no-final assertions non-vacuous. Silence decodes slowly, so the
# run polls for the terminal state instead of assuming a fixed window.
# Run C (tray Close during Recording, keys held): S9 — cancels, discards,
# exits; capture must never reach Processing.
# Run D (tray Close during Processing): S9 — cancels the final inference,
# exits without delivering a result.
# Also asserts the process connects only to the engine it checked (R3a).
# Close during Loading is not reachable here: Loading spans only the
# microphone opening, far below tray-menu latency.
# Run from WSL: powershell.exe -ExecutionPolicy Bypass -File scripts\smoke-loading-stop.ps1 [-StartEngine]

param(
    # The user's engine (D23). It must already be running, unless
    # -StartEngine is given: the user authorized that for M2b proof runs only.
    [string]$Endpoint = "http://127.0.0.1:8080/inference",
    [switch]$StartEngine,
    [string]$EngineExe = "C:\openai-whisper\whisper-bin-x64-v1.9.2\Release\whisper-server.exe",
    [string]$EngineModel = "C:\openai-whisper\ggml-base-q5_1.bin"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms

$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
. (Join-Path $PSScriptRoot "lib-tray.ps1")
. (Join-Path $PSScriptRoot "lib-engine.ps1")
$engineProcess = $null

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\release\viby.exe"
$storeFile = Join-Path $env:APPDATA "com.viby.local\preferences.json"
$storeExisted = Test-Path $storeFile
$storeBackup = if ($storeExisted) { [System.IO.File]::ReadAllBytes($storeFile) } else { $null }
$logFile = Join-Path $env:TEMP "viby-flow-trace.log"
$errFile = Join-Path $env:TEMP "viby-flow-trace.err"
$proc = $null
$viby = $null

Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, System.UIntPtr e);' `
    -Name K2 -Namespace WLS -ErrorAction SilentlyContinue

# cmd redirection writes the trace file eagerly; PowerShell's own
# -RedirectStandardOutput only flushes after the child exits.
function Start-Viby {
    Remove-Item $logFile, $errFile -Force -ErrorAction SilentlyContinue
    $cmdline = '/c ""{0}" > "{1}" 2> "{2}""' -f $exe, $logFile, $errFile
    $launched = Start-Process cmd.exe -PassThru -WindowStyle Hidden -ArgumentList $cmdline
    Start-Sleep -Seconds 3
    # The preflight refuses to run beside a pre-existing instance, so the only
    # viby process here is ours. Own its PID: cleanup must never kill a user's
    # instance by executable name after a mid-run failure.
    $started = Get-Process viby -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $started) {
        throw "viby.exe did not start (cmd pid $($launched.Id))"
    }
    $script:viby = $started
    return $launched
}

function Stop-Viby {
    if ($script:viby -and -not $script:viby.HasExited) {
        Stop-Process -Id $script:viby.Id -Force -ErrorAction SilentlyContinue
        $script:viby.WaitForExit(5000) | Out-Null
    }
    $script:viby = $null
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $script:proc = $null
    # the OS needs a beat to release the killed process's hotkey registration
    Start-Sleep -Seconds 2
}

function Send-Hold($milliseconds) {
    [WLS.K2]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
    Start-Sleep -Milliseconds $milliseconds
    [WLS.K2]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
}

function Read-FlowStates($sinceLine) {
    $lines = Get-Content $logFile -ErrorAction SilentlyContinue
    $states = @()
    for ($i = $sinceLine; $i -lt $lines.Count; $i++) {
        # tracing styles field names; drop ANSI escapes before matching
        $clean = $lines[$i] -replace "$([char]27)\[[0-9;]*m", ''
        if ($clean -match 'flow state.*state=(\w+)') {
            $next = $Matches[1]
            if ($states.Count -eq 0 -or $states[-1] -ne $next) { $states += $next }
        }
    }
    return @{ States = $states; Lines = $lines.Count }
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

# A raced Final also ends in Idle, but with message=None; only the cancel
# path carries the static cancellation message. This assertion is what
# mutation-protects "Close discards the result" without logging any text.
function Assert-CancelledNotDelivered($label) {
    $clean = (Get-Content $logFile -ErrorAction SilentlyContinue) -replace "$([char]27)\[[0-9;]*m", ''
    if (-not ($clean | Where-Object { $_ -match 'state=Idle' -and $_ -match 'Some\("Canceled' })) {
        throw "$label did not record the cancellation message; a result may have been delivered"
    }
}

# Event-level proof that Close delivered no result: the production final path
# logs `flow final` (counts and timing only) when it commits FlowEvent::Final,
# so its absence means nothing was delivered.
function Assert-NoFinalDelivered($label) {
    $clean = (Get-Content $logFile -ErrorAction SilentlyContinue) -replace "$([char]27)\[[0-9;]*m", ''
    $final = @($clean | Where-Object { $_ -match 'flow final' })
    if ($final.Count -gt 0) {
        throw "$label delivered a final result after Close: $($final -join ' | ')"
    }
}

# Mandatory positive control for the assertion above. Without an observed
# delivery in the same run, a silently removed marker would make every
# no-final assertion vacuous. `delivered=true` is the emit result itself, so
# this also fails if the webview event stops being published.
function Assert-FinalDelivered($label) {
    $clean = (Get-Content $logFile -ErrorAction SilentlyContinue) -replace "$([char]27)\[[0-9;]*m", ''
    $final = @($clean | Where-Object { $_ -match 'flow final.*chars=\d+.*delivered=true' })
    if ($final.Count -eq 0) {
        throw "$label never logged a delivered final result; the no-final assertions would be vacuous"
    }
}

# Silence decodes pathologically slowly (observed >15 s), so the positive
# control polls for the terminal state instead of assuming a fixed window.
function Wait-ForFinal($timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $clean = (Get-Content $logFile -ErrorAction SilentlyContinue) -replace "$([char]27)\[[0-9;]*m", ''
        if ($clean | Where-Object { $_ -match 'flow final' }) { return }
        Start-Sleep -Seconds 2
    }
}

try {
    if ($StartEngine) { $engineProcess = Start-ProofEngine $Endpoint $EngineExe $EngineModel }
    if (-not (Test-EngineListening $Endpoint)) { throw "no engine listens on $Endpoint; start it or pass -StartEngine" }
    $prefs = Get-Content $storeFile -Raw | ConvertFrom-Json
    Set-EnginePrefs $prefs.preferences $Endpoint
    $prefs.preferences.shortcut = "Ctrl+Shift+Space"
    # serde_json rejects a BOM; write strict UTF-8
    [System.IO.File]::WriteAllText($storeFile, ($prefs | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))

    # A stale instance silently steals the global shortcut registration and
    # every hotkey assertion degrades into misleading flow evidence.
    if (Get-Process viby -ErrorAction SilentlyContinue) {
        throw "another Viby process is running; smoke refuses to terminate it"
    }

    $proc = Start-Viby
    Start-Sleep -Seconds 10
    Send-Hold 250
    Start-Sleep -Seconds 8
    Stop-Viby
    Start-Sleep -Seconds 1
    $runA = Read-FlowStates 0
    Write-Output ("run-a-sequence: " + ($runA.States -join " -> "))
    if ($runA.States.Count -eq 0) {
        $procs = @(Get-Process viby -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ","
        $quarantined = Test-Path (Join-Path (Split-Path $storeFile) "preferences.bak")
        throw "run A observed no flow state (viby pids=[$procs]; store quarantined=$quarantined; shortcut registration likely failed)"
    }
    # A short hold still orders the activation signal before Processing; the
    # terminal state depends on what the engine makes of 250 ms of audio.
    Assert-Order $runA.States @("Loading", "Processing") "run A"
    Write-Output "run-a-short-hold: PASS (Loading before Processing)"

    $proc = Start-Viby
    Start-Sleep -Seconds 10
    Send-Hold 1500
    Start-Sleep -Seconds 5
    $viby = $script:viby
    if ($viby) {
        $count = Assert-EngineOnlyConnections $viby.Id $Endpoint "run B"
        Write-Output "network-observation: ENGINE ONLY ($count connection(s) to $Endpoint)"
    }
    Wait-ForFinal 240
    Stop-Viby
    Start-Sleep -Seconds 1
    $runB = Read-FlowStates 0
    Write-Output ("run-b-sequence: " + ($runB.States -join " -> "))
    # This target's keyboard stack occasionally injects a phantom short
    # press/release cycle before the real hold; Assert-Order tolerates the
    # leading cycle while still requiring the ordered real one.
    Assert-Order $runB.States @("Loading", "Recording", "Processing", "Idle") "run B"
    Write-Output "run-b-hold-to-talk-order: PASS"
    Assert-FinalDelivered "run B"
    Write-Output "run-b-final-event: PASS (production final path delivered a result)"

    # Run C — tray Close during Recording (keys held): S9 capture phase.
    $proc = Start-Viby
    Start-Sleep -Seconds 10
    # Materialize the tray icon BEFORE holding keys: Win+B needs free modifiers.
    $icon = $null
    for ($try = 0; $try -lt 8 -and -not $icon; $try++) {
        $icon = Find-TrayIcon
        if (-not $icon) { Start-Sleep -Milliseconds 800 }
    }
    if (-not $icon) { throw "run C could not locate the Viby tray icon" }
    # Cache the coordinates now: the UIA element goes stale during the hold,
    # but the tray icon does not move. Right-click must not need UIA later.
    $iconRect = $icon.Current.BoundingRectangle
    [WLS.K2]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x10, 0, 0, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x20, 0, 0, [System.UIntPtr]::Zero)
    Start-Sleep -Seconds 4
    Right-Click-At ([int]($iconRect.X + $iconRect.Width / 2)) ([int]($iconRect.Y + $iconRect.Height / 2))
    Start-Sleep -Milliseconds 1200
    Get-TrayMenuItems | Out-Null
    Invoke-TrayMenuItem "Close"
    [WLS.K2]::keybd_event(0x20, 0, 2, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x10, 0, 2, [System.UIntPtr]::Zero)
    [WLS.K2]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
    $viby = $script:viby
    if ($viby) {
        $viby.WaitForExit(12000) | Out-Null
        if (-not $viby.HasExited) { throw "Close during Recording did not exit the process" }
    }
    $script:proc = $null
    Start-Sleep -Seconds 1
    $runC = Read-FlowStates 0
    Write-Output ("run-c-sequence: " + ($runC.States -join " -> "))
    Assert-Order $runC.States @("Loading", "Recording", "Idle") "run C"
    if (($runC.States -join " -> ") -match "Processing") {
        throw "Close during Recording still processed audio: $($runC.States -join ' -> ')"
    }
    Assert-CancelledNotDelivered "run C"
    Assert-NoFinalDelivered "run C"
    Write-Output "run-c-close-during-recording: PASS (cancelled, exited, nothing processed, no final event)"

    # Run D — tray Close during Processing: S9 final-inference phase. The
    # silent decode keeps Processing open far longer than the close wait.
    $proc = Start-Viby
    Start-Sleep -Seconds 10
    Send-Hold 1500
    Start-Sleep -Seconds 3
    Open-TrayMenu | Out-Null
    Get-TrayMenuItems | Out-Null
    Invoke-TrayMenuItem "Close"
    $viby = $script:viby
    if ($viby) {
        $viby.WaitForExit(12000) | Out-Null
        if (-not $viby.HasExited) { throw "Close during Processing did not exit the process" }
    }
    $script:proc = $null
    Start-Sleep -Seconds 1
    $runD = Read-FlowStates 0
    Write-Output ("run-d-sequence: " + ($runD.States -join " -> "))
    Assert-Order $runD.States @("Loading", "Recording", "Processing", "Idle") "run D"
    Assert-CancelledNotDelivered "run D"
    Assert-NoFinalDelivered "run D"
    Write-Output "run-d-close-during-processing: PASS (final discarded, exited, no final event)"
    Write-Output "`nSMOKE PASS"
} finally {
    Stop-ProofEngine $engineProcess
    Stop-Viby
    if ($storeExisted) {
        [System.IO.File]::WriteAllBytes($storeFile, $storeBackup)
    } else {
        Remove-Item $storeFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path (Split-Path $storeFile) "preferences.bak") -Force -ErrorAction SilentlyContinue
}
