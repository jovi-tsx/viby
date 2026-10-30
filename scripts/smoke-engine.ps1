# Engine bridge smoke (M2b, D23): the production request path against the
# user's real whisper.cpp server, with a spoken take synthesized by Windows
# SAPI so no microphone or operator is needed. Starts and stops the user's
# engine only with -StartEngine (authorized for M2b proof runs).
#
# Counts only: the transcript is never printed or logged (R5).
#
# Run from WSL:
#   powershell.exe -ExecutionPolicy Bypass -File scripts\smoke-engine.ps1 -StartEngine
#   ... -Endpoint http://<private address>:8080/inference -AllowLocalNetwork -StartEngine
param(
    [string]$Endpoint = "http://127.0.0.1:8080/inference",
    [switch]$StartEngine,
    [switch]$AllowLocalNetwork,
    [string]$EngineExe = "C:\openai-whisper\whisper-bin-x64-v1.9.2\Release\whisper-server.exe",
    [string]$EngineModel = "C:\openai-whisper\ggml-base-q5_1.bin",
    [string]$Phrase = "The quick brown fox jumps over the lazy dog near the river bank.",
    [string]$Expect = "quick,brown,fox,lazy,dog,river"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib-engine.ps1")
$repo = Split-Path $PSScriptRoot -Parent
$wav = Join-Path $env:TEMP "viby-smoke-engine.wav"
$engineProcess = $null
try {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,
        [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
        [System.Speech.AudioFormat.AudioChannel]::Mono)
    $synth.SetOutputToWaveFile($wav, $format)
    $synth.Speak($Phrase)
    $synth.Dispose()
    Write-Output ("spoken-take: {0:N1} s synthesized" -f (((Get-Item $wav).Length - 44) / 32000))

    if ($StartEngine) {
        $engineProcess = Start-ProofEngine $Endpoint $EngineExe $EngineModel
        Write-Output "engine: started $EngineExe ($([System.IO.Path]::GetFileName($EngineModel))) on $Endpoint"
    }
    if (-not (Test-EngineListening $Endpoint)) { throw "no engine listens on $Endpoint; start it or pass -StartEngine" }

    $env:VIBY_SMOKE_ENDPOINT = $Endpoint
    $env:VIBY_SMOKE_WAV = $wav
    $env:VIBY_SMOKE_EXPECT = $Expect
    $env:VIBY_SMOKE_ALLOW_LAN = if ($AllowLocalNetwork) { "1" } else { "0" }
    Push-Location (Join-Path $repo "src-tauri")
    # cargo reports progress on stderr; PowerShell 5.1 would turn that into a
    # terminating error under Stop.
    $ErrorActionPreference = "Continue"
    try {
        cargo test --lib --no-run 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        cargo test --lib a_real_engine_transcribes_a_spoken_take -- --ignored --nocapture 2>&1 |
            Where-Object { $_ -match "REAL_ENGINE|test result|panicked" } | ForEach-Object { "$_" }
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = "Stop"
        Pop-Location
    }
    if ($exit -ne 0) { throw "engine smoke failed (exit $exit)" }
    Write-Output "`nSMOKE PASS"
} finally {
    Stop-ProofEngine $engineProcess
    Remove-Item $wav -Force -ErrorAction SilentlyContinue
    foreach ($name in "VIBY_SMOKE_ENDPOINT", "VIBY_SMOKE_WAV", "VIBY_SMOKE_EXPECT", "VIBY_SMOKE_ALLOW_LAN") {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
}
