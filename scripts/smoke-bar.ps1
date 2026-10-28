# M3 bar smoke: the bottom capsule, its states, its controls, and the
# positions from D9. Evidence channels are the real Windows window (UIA tree,
# window rectangle, screenshots) and the app's own tracing log.
#
# Narrator announcement capture and the 200% scaling pass are NOT part of this
# script and must not be added: this environment has no interactive Narrator
# session and no 200% display (user decision 2026-08-15, see AGENTS.md). The
# live-region contract is proven through the announcing elements themselves.
#
# Runs, all against the real global shortcut and the production flow:
#   A  left/center/right - geometry, safe inset, no focus theft, recording
#      surface (waveform state, Stop, Cancel), then Cancel during capture (S2)
#   B  the bar's Stop control ends capture while the keys are still held,
#      then Cancel during processing
#   C  missing local model - actionable error, no network (S3)
#   D  unavailable microphone - error instead of a recording state (S4)
#   E  Windows animations off - static meter instead of a waveform (S6)
#   F  spoken run (-Spoken): provisional preview, then Success (S7)
#
# Run from WSL:
#   powershell.exe -ExecutionPolicy Bypass -File scripts\smoke-bar.ps1 `
#       -ModelPath C:\openai-whisper\ggml-base-q5_1.bin [-Spoken]

param(
    [string]$ModelPath = "C:\openai-whisper\ggml-base-q5_1.bin",
    [string]$Variant = "base-q5_1",
    # A silence decode on `small` is slow enough that a cancellation teardown
    # is observable; the busy run needs that window.
    [string]$SlowModelPath = "C:\openai-whisper\ggml-small.bin",
    [switch]$Spoken
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
$animationsRestore = $null
$webviewProfile = Join-Path $env:TEMP "viby-smoke-webview"

. (Join-Path $PSScriptRoot "lib-bar.ps1")

try {
    if (-not (Test-Path $exe)) { throw "release executable not found: $exe (run cargo tauri build)" }
    if (-not (Test-Path $ModelPath)) { throw "model file not found: $ModelPath" }
    $work = Get-WorkArea
    Note ("work-area: {0},{1} {2}x{3}" -f $work.Left, $work.Top,
        ($work.Right - $work.Left), ($work.Bottom - $work.Top))
    Note ("foreground-at-start: " + (Get-ForegroundInfo))

    # --- A. positions, focus preservation, recording surface, Cancel (S2) ---
    foreach ($position in @("left", "center", "right")) {
        Write-Prefs { param($p) $p.preferences.interface.bar_position = $position }
        Start-Viby
        $foreground = [VB.Bar]::GetForegroundWindow()
        Hold-Down
        try {
            $bar = Wait-ForBar 15
            if (-not (Wait-ForState "Recording" 15)) { throw "$position run never reached Recording" }
            Start-Sleep -Milliseconds 700
            $bar = Wait-ForBar 5
            Assert-Geometry $bar $position $work

            # The contract is that Viby never takes the foreground: an
            # unrelated window activating during the run is the environment's
            # business, so the assertion names Viby instead of comparing
            # handles, which would fail on someone else's focus change.
            $after = [VB.Bar]::GetForegroundWindow()
            $barHandle = [System.IntPtr]$bar.Current.NativeWindowHandle
            if ($after -eq $barHandle) { throw "$position capsule became the foreground window" }
            $ownerPid = 0
            [void][VB.Bar]::GetWindowThreadProcessId($after, [ref]$ownerPid)
            if ($ownerPid -eq $script:viby.Id) {
                throw "$position run put a Viby window in the foreground"
            }
            Note ("focus-preserved-$position`: PASS (foreground pid=$ownerPid, unchanged=" +
                ($after -eq $foreground) + ")")

            $elements = Wait-ForName $bar "*Listening*" "$position recording surface"
            Assert-NoName $elements "*Loading*" "$position recording surface"
            # With `confirm_before_insert` off — the default — releasing the
            # shortcut is the send, so no accept control exists at any point.
            if (Get-Button $elements "Accept") {
                throw "$position run offered an accept control with confirmation off"
            }
            if (-not (Get-Button $elements "Cancel")) { throw "$position run has no Cancel control" }
            if ($elements | Where-Object { $_.Type -eq "ControlType.ProgressBar" }) {
                throw "$position run shows the static meter while animations are enabled"
            }
            $shot = Capture ("bar-recording-$position.png") $bar
            Note "capture-recording-$position`: $shot"
            ($elements | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
                Set-Content (Join-Path $artifacts "uia-recording-$position.txt")

            if ($position -eq "center") {
                $connections = Get-NetTCPConnection -OwningProcess $script:viby.Id -ErrorAction SilentlyContinue
                if ($connections) { throw "viby.exe held TCP connections while the bar was live" }
                Note "network-observation: NO TCP CONNECTIONS"
            }

            # S2: Cancel during capture discards everything and inserts nothing.
            # The Cancel IPC travels UIA -> webview -> Rust, while the release
            # travels keyboard -> Rust. Releasing before the cancellation has
            # landed lets the stop win the race, so wait for the observable
            # barrier first: the controller hides the dock the moment it arms
            # the flag.
            $cancelHandle = [System.IntPtr]$bar.Current.NativeWindowHandle
            Invoke-BarButton $elements "Cancel"
            $cancelDeadline = (Get-Date).AddSeconds(5)
            while ([VB.Bar]::IsWindowVisible($cancelHandle) -and (Get-Date) -lt $cancelDeadline) {
                Start-Sleep -Milliseconds 50
            }
            if ([VB.Bar]::IsWindowVisible($cancelHandle)) {
                throw "$position Cancel did not reach the flow within 5s"
            }
        } finally {
            Hold-Up
        }
        if (-not (Wait-ForState "Idle" 10)) { throw "$position Cancel did not end the flow" }
        Assert-Cancelled "$position Cancel"
        Assert-NoFinalDelivered "$position Cancel"
        $states = Get-FlowStates
        Note ("state-sequence-$position`: " + ($states -join " -> "))
        if (($states -join " -> ") -match "Processing") {
            throw "$position Cancel during capture still processed audio"
        }
        # The capsule returns to the tray once the outcome has been readable.
        Assert-BarAtRest "cancel-during-capture-$position"
        Note "cancel-during-capture-$position`: PASS (nothing processed, capsule at rest)"
        Stop-Viby
    }

    # --- B. release ends capture; the dock keeps only what still applies -----
    Write-Prefs $null
    Start-Viby
    Hold-Down
    try {
        $bar = Wait-ForBar 15
        if (-not (Wait-ForState "Recording" 15)) { throw "run B never reached Recording" }
        Start-Sleep -Milliseconds 700
        $elements = Wait-ForName (Wait-ForBar 5) "*Listening*" "run B capture surface"
        Hold-Up
        if (-not (Wait-ForState "Processing" 10)) {
            throw "releasing the shortcut did not end capture"
        }
        Note "release-ends-capture: PASS"
        $bar = Wait-ForBar 5
        $elements = Wait-ForName $bar "*Processing*" "run B processing surface"
        if ($elements | Where-Object { $_.Type -eq "ControlType.ProgressBar" }) {
            throw "processing still shows an audio level; the microphone is closed"
        }
        if (Get-Button $elements "Accept") { throw "processing offered an accept control" }
        if (-not (Get-Button $elements "Cancel")) { throw "Cancel is missing during processing" }
        $shot = Capture "bar-processing.png" $bar
        Note "capture-processing: $shot"
        ($elements | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
            Set-Content (Join-Path $artifacts "uia-processing.txt")
        # Keyboard operability: the capsule takes focus only when the user
        # explicitly activates it with a click, and its controls are then
        # reachable in DOM order and invokable from the keyboard alone.
        $rect = $bar.Current.BoundingRectangle
        # The dock sits at the bottom of a taller transparent window; clicking
        # the window's middle would land on the desktop behind it.
        Click-At ([int]($rect.X + $rect.Width / 2)) ([int]($rect.Y + $rect.Height - 28))
        Start-Sleep -Milliseconds 600
        $focusPath = @()
        $cancelFocused = $false
        for ($tab = 0; $tab -lt 4 -and -not $cancelFocused; $tab++) {
            Send-Key 0x09
            Start-Sleep -Milliseconds 300
            $focused = $AE::FocusedElement
            $focusPath += "$($focused.Current.ControlType.ProgrammaticName)='$($focused.Current.Name)'"
            $cancelFocused = ($focused.Current.Name -eq "Cancel")
        }
        Note ("keyboard-focus-order: " + ($focusPath -join " -> "))
        if (-not $cancelFocused) { throw "Cancel is not reachable with Tab after activation" }
        Send-Key 0x20
    } finally {
        Hold-Up
    }
    if (-not (Wait-ForState "Idle" 15)) { throw "run B Cancel did not end the flow" }
    Assert-Cancelled "run B Cancel during processing"
    Assert-NoFinalDelivered "run B Cancel during processing"
    Note "cancel-during-processing: PASS (no result delivered)"
    Stop-Viby

    # --- B2. a press during teardown is explained, not swallowed -----------
    # Cancel returns the dock at once while the worker still discards buffers
    # and reaps the inference thread. A press arriving inside that window must
    # be refused, not swallowed. Two asynchronous paths meet here, so the run
    # does not hope for an ordering — it observes one:
    #   barrier 1  the dock disappears. `FlowController::cancel` hides it after
    #              arming the flag and before the worker is even told, so a
    #              hidden dock proves the cancellation reached the backend.
    #   barrier 2  the last logged state is not Idle, so the teardown is still
    #              in flight at the moment of the press.
    # Only when both hold is the notice required. Otherwise the attempt was
    # inconclusive — the teardown simply finished first — and is retried. The
    # slow model widens the window: its silence decode makes the abort visible.
    $busySeen = $null
    $busyLogged = $false
    $ordered = 0
    for ($attempt = 1; $attempt -le 5 -and -not $busySeen; $attempt++) {
        Write-Prefs {
            param($p)
            $p.preferences.model.path = $SlowModelPath
            $p.preferences.model.variant = "small"
        }
        Start-Viby
        Hold-Down
        try {
            $bar = Wait-ForBar 15
            if (-not (Wait-ForState "Recording" 15)) { throw "busy run never reached Recording" }
            Start-Sleep -Milliseconds 600
            $elements = Wait-ForName (Wait-ForBar 5) "*Listening*" "busy run capture surface"
        } finally {
            Hold-Up
        }
        if (-not (Wait-ForState "Processing" 15)) { throw "busy run never reached Processing" }
        $handle = [System.IntPtr]$bar.Current.NativeWindowHandle
        Invoke-BarButton $elements "Cancel"
        $hidden = $false
        $barrier = (Get-Date).AddSeconds(2)
        while (-not $hidden -and (Get-Date) -lt $barrier) {
            $hidden = -not [VB.Bar]::IsWindowVisible($handle)
            if (-not $hidden) { Start-Sleep -Milliseconds 20 }
        }
        $states = Get-FlowStates
        $windingDown = $hidden -and $states.Count -gt 0 -and $states[-1] -ne "Idle"
        if ($windingDown) {
            $ordered++
            # A real tap of the configured shortcut; the press alone is what
            # start_dictation sees.
            Hold-Down
            Start-Sleep -Milliseconds 80
            Hold-Up
            $deadline = (Get-Date).AddSeconds(4)
            while (-not $busySeen -and (Get-Date) -lt $deadline) {
                if (Get-CleanLog | Where-Object { $_ -match 'flow busy' }) { $busyLogged = $true }
                $bar = Get-BarWindow
                if ($bar -and -not $bar.Current.IsOffscreen) {
                    $notice = Get-BarElements $bar
                    $busySeen = $notice | Where-Object { $_.Name -like "*moment*" } | Select-Object -First 1
                    if ($busySeen) {
                        $shot = Capture "bar-busy.png" $bar
                        Note "capture-busy: $shot"
                        ($notice | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
                            Set-Content (Join-Path $artifacts "uia-busy.txt")
                    }
                }
                Start-Sleep -Milliseconds 100
            }
        }
        Note ("busy-notice-attempt-$attempt`: ordered=$windingDown refused=$busyLogged plate=" +
            [bool]$busySeen)
        Stop-Viby
    }
    if ($ordered -eq 0) {
        # Never a spurious failure: the product cannot be blamed for tearing
        # down faster than a keystroke can be injected.
        Note "busy-notice: NOT OBSERVED (teardown finished before every press; start_decision is covered by unit tests)"
    } else {
        if (-not $busyLogged) {
            throw "a press during an in-flight teardown was not refused ($ordered ordered attempts)"
        }
        if (-not $busySeen) { throw "the refusal never reached the dock as a visible notice" }
        Note ("busy-notice: PASS (" + $busySeen.Name + ")")
    }

    # --- B3. confirm before inserting: accept, then discard -----------------
    # With the preference on, a finished transcript waits on the dock instead of
    # leaving. Accept resolves it (M4 inserts from exactly this point); Cancel
    # discards it. Both outcomes are traced as `flow confirmation accepted=…`,
    # counts and outcomes only, never text.
    foreach ($choice in @("Accept", "Cancel")) {
        # A store written before this preference existed has no such property;
        # serde defaults it on read, so the harness must add it explicitly.
        Write-Prefs {
            param($p)
            $p.preferences.insertion | Add-Member -NotePropertyName confirm_before_insert `
                -NotePropertyValue $true -Force
        }
        Start-Viby
        # D16: with confirm_before_insert on, activation is press-once, not
        # hold-to-talk — a short tap opens the microphone and the key is not
        # held; a second tap (after "speaking") ends the take. Holding across
        # the wait, as the pre-D16 version of this scenario did, leaves the
        # take open forever because release no longer ends it in this mode.
        Hold-Down
        Start-Sleep -Milliseconds 80
        Hold-Up
        $bar = Wait-ForBar 15
        if (-not (Wait-ForState "Recording" 15)) { throw "confirm run never reached Recording" }
        Start-Sleep -Milliseconds 1500
        Hold-Down
        Start-Sleep -Milliseconds 80
        Hold-Up
        if (-not (Wait-ForState "Processing" 15)) { throw "confirm run never reached Processing" }
        if (-not (Wait-ForState "Confirming" 180)) {
            throw "the finished transcript did not wait for a confirmation"
        }
        $bar = Wait-ForBar 10
        $elements = Wait-ForName $bar "*Ready to insert*" "confirm run"
        if (-not (Get-Button $elements "Accept")) { throw "the confirmation step has no accept control" }
        if (-not (Get-Button $elements "Cancel")) { throw "the confirmation step has no discard control" }
        if ($elements | Where-Object { $_.Type -eq "ControlType.ProgressBar" }) {
            throw "the confirmation step still shows an audio level"
        }
        # It must actually wait: no linger may take it away on its own.
        Start-Sleep -Seconds 4
        $handle = [System.IntPtr]$bar.Current.NativeWindowHandle
        if (-not [VB.Bar]::IsWindowVisible($handle)) {
            throw "the confirmation step disappeared without a decision"
        }
        if ($choice -eq "Accept") {
            $shot = Capture "bar-confirming.png" $bar
            Note "capture-confirming: $shot"
            ($elements | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
                Set-Content (Join-Path $artifacts "uia-confirming.txt")
        }
        Invoke-BarButton $elements $choice
        if (-not (Wait-ForState "Idle" 10)) { throw "$choice did not resolve the confirmation" }
        $expected = if ($choice -eq "Accept") { "accepted=true" } else { "accepted=false" }
        if (-not (Get-CleanLog | Where-Object { $_ -match "flow confirmation" -and $_ -match $expected })) {
            throw "$choice did not record '$expected'"
        }
        Assert-BarAtRest "confirm-$choice"
        Note "confirm-before-insert-$choice`: PASS ($expected)"
        Stop-Viby
    }

    # --- C. missing local model (S3) ----------------------------------------
    Write-Prefs { param($p) $p.preferences.model.path = $null }
    Start-Viby
    Hold-Down
    Start-Sleep -Milliseconds 900
    Hold-Up
    if (-not (Wait-ForState "Error" 20)) { throw "the missing model did not end in an error state" }
    $bar = Wait-ForBar 10
    $elements = Wait-ForName $bar "*no local Whisper model is configured*" "run C"
    Assert-Name $elements "*Options*" "run C"
    Assert-Name $elements "*Error*" "run C"
    Assert-NoName $elements "*Listening*" "run C"
    $connections = Get-NetTCPConnection -OwningProcess $script:viby.Id -ErrorAction SilentlyContinue
    if ($connections) { throw "the missing-model error opened a connection" }
    Assert-NoFinalDelivered "run C"
    $shot = Capture "bar-error-missing-model.png" $bar
    Note "capture-error-missing-model: $shot"
    ($elements | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
        Set-Content (Join-Path $artifacts "uia-error-missing-model.txt")
    Note "missing-model-error: PASS (actionable, local, no network)"
    Stop-Viby

    # --- D. unavailable microphone (S4) -------------------------------------
    Write-Prefs { param($p) $p.preferences.microphone = "Viby smoke absent capture device" }
    Start-Viby
    Hold-Down
    Start-Sleep -Milliseconds 900
    Hold-Up
    if (-not (Wait-ForState "Error" 20)) { throw "the absent microphone did not end in an error state" }
    $states = Get-FlowStates
    if (($states -join " -> ") -match "Recording") {
        throw "the bar entered a recording state without a microphone: $($states -join ' -> ')"
    }
    $bar = Wait-ForBar 10
    $elements = Wait-ForName $bar "*microphone is not available*" "run D"
    Assert-NoName $elements "*Listening*" "run D"
    $shot = Capture "bar-error-microphone.png" $bar
    Note "capture-error-microphone: $shot"
    ($elements | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
        Set-Content (Join-Path $artifacts "uia-error-microphone.txt")
    Note ("microphone-error: PASS (no recording state; " + ($states -join " -> ") + ")")
    Stop-Viby

    # --- E. Windows animations off: static meter, no waveform (S6) ----------
    $animationsRestore = Get-Animations
    Note "client-area-animation-before: $animationsRestore"
    Set-Animations $false
    Write-Prefs $null
    Start-Viby
    Hold-Down
    try {
        $bar = Wait-ForBar 15
        if (-not (Wait-ForState "Recording" 15)) { throw "run E never reached Recording" }
        Start-Sleep -Seconds 1
        $bar = Wait-ForBar 5
        $elements = Wait-ForName $bar "*Listening*" "run E reduced motion"
        $meter = $elements | Where-Object { $_.Type -eq "ControlType.ProgressBar" } | Select-Object -First 1
        if (-not $meter) {
            throw "reduced motion did not replace the waveform with a static meter"
        }
        Note ("reduced-motion-meter: PASS (" + $meter.Name + ")")
        $shot = Capture "bar-reduced-motion.png" $bar
        Note "capture-reduced-motion: $shot"
        ($elements | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
            Set-Content (Join-Path $artifacts "uia-reduced-motion.txt")
        Invoke-BarButton $elements "Cancel"
    } finally {
        Hold-Up
        Set-Animations $animationsRestore
        $animationsRestore = $null
    }
    if (-not (Wait-ForState "Idle" 10)) { throw "run E Cancel did not end the flow" }
    Stop-Viby

    # --- F. spoken run: provisional preview, then Success (S7) --------------
    if ($Spoken) {
        Write-Prefs $null
        Start-Viby
        Write-Output ""
        Write-Output "OPERATOR: hold Ctrl+Shift+Space is automated. Speak a full"
        Write-Output "          sentence as soon as the capsule shows Listening."
        Write-Output ""
        Hold-Down
        $previewSeen = $null
        try {
            $bar = Wait-ForBar 15
            if (-not (Wait-ForState "Recording" 15)) { throw "run F never reached Recording" }
            # A silent first window can hold the inference slot for several
            # seconds (silence decodes pathologically slowly), so the spoken
            # preview lands later than intuition suggests. The poll outlasts
            # that by design.
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $previewSeen -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
                $bar = Get-BarWindow
                if (-not $bar) { continue }
                $elements = Get-BarElements $bar
                $previewSeen = $elements |
                    Where-Object { $_.Name -like "*Provisional*" -and $_.Name.Length -gt "Provisional".Length + 2 } |
                    Select-Object -First 1
                if ($previewSeen) {
                    $shot = Capture "bar-preview.png" $bar
                    Note "capture-preview: $shot"
                    ($elements | ForEach-Object { "$($_.Type)`t$($_.Name)" }) |
                        Set-Content (Join-Path $artifacts "uia-preview.txt")
                }
            }
        } finally {
            Hold-Up
        }
        # Two halves of the same proof: the production path emitted a preview
        # with real characters, and the dock put it on screen labeled
        # provisional. The trace is what separates "no preview was produced"
        # from "the preview was produced but not rendered".
        $previewLogged = Get-CleanLog | Where-Object { $_ -match 'flow preview' -and $_ -match 'chars=([1-9]\d*)' -and $_ -match 'delivered=true' } |
            Select-Object -First 1
        if (-not $previewLogged) {
            throw "no provisional preview was emitted while speaking (trace has no 'flow preview' with chars and delivered=true)"
        }
        Note ("preview-emitted: PASS (" + $previewLogged.Substring($previewLogged.IndexOf('chars=')) + ")")
        if (-not $previewSeen) { throw "the emitted provisional preview never appeared on the dock" }
        # The preview is labeled provisional and carries only the current
        # window; nothing is inserted from it (D4).
        Note "provisional-preview: PASS (labeled, replaced in place)"
        $deadline = (Get-Date).AddSeconds(120)
        $finalLine = $null
        while (-not $finalLine -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $finalLine = Get-CleanLog | Where-Object { $_ -match 'flow final' } | Select-Object -First 1
            $bar = Get-BarWindow
            if ($bar -and -not $bar.Current.IsOffscreen) {
                $success = Get-BarElements $bar | Where-Object { $_.Name -like "*Success*" } | Select-Object -First 1
                if ($success -and -not $script:successShot) {
                    $script:successShot = Capture "bar-success.png" $bar
                }
            }
        }
        if (-not $finalLine) { throw "no final result within 120 s" }
        if ($finalLine -notmatch 'delivered=true') { throw "final result not delivered: $finalLine" }
        if ($finalLine -notmatch 'chars=([1-9]\d*)') { throw "final result was empty: $finalLine" }
        Note ("spoken-final: PASS (" + $finalLine.Substring($finalLine.IndexOf('chars=')) + ")")
        if (-not $script:successShot) { throw "the capsule never showed the Success state" }
        Note "capture-success: $($script:successShot)"
        Assert-BarAtRest "success-then-rest"
        Note "success-then-rest: PASS"
        Stop-Viby
    } else {
        Note "spoken-preview: SKIPPED (-Spoken not given)"
    }

    Note "`nSMOKE PASS"
} finally {
    Stop-Viby
    if ($animationsRestore -ne $null) { Set-Animations $animationsRestore }
    if ($storeExisted) { [System.IO.File]::WriteAllBytes($storeFile, $storeBackup) }
    Remove-Item (Join-Path (Split-Path $storeFile) "preferences.bak") -Force -ErrorAction SilentlyContinue
    Remove-Item $webviewProfile -Recurse -Force -ErrorAction SilentlyContinue
    $report | Set-Content (Join-Path $artifacts "smoke-bar-report.txt")
}
