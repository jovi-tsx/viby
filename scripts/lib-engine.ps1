# Shared engine helpers for the native smokes (D23, ADR 0002). Dot-source.
#
# Viby never starts an engine. The smokes expect the user's engine to be
# running already; `Start-ProofEngine` exists only for the M2b proof runs the
# user authorized (DECISIONS.md, D23 third addendum) and is reached through an
# explicit -StartEngine switch, never by default.

$DEFAULT_ENGINE_ENDPOINT = "http://127.0.0.1:8080/inference"
$DEFAULT_ENGINE_EXE = "C:\openai-whisper\whisper-bin-x64-v1.9.2\Release\whisper-server.exe"
$DEFAULT_ENGINE_MODEL = "C:\openai-whisper\ggml-base-q5_1.bin"

# Points a parsed store at an engine. The pre-D23 model fields are dropped so
# the run exercises the store shape this revision writes.
function Set-EnginePrefs($preferences, [string]$endpoint, [bool]$allowLocalNetwork = $false) {
    $engine = [pscustomobject]@{ endpoint = $endpoint; allow_local_network = $allowLocalNetwork }
    $preferences | Add-Member -NotePropertyName engine -NotePropertyValue $engine -Force
    $language = "auto"
    if ($preferences.model -and $preferences.model.language) { $language = $preferences.model.language }
    $preferences | Add-Member -NotePropertyName model -Force `
        -NotePropertyValue ([pscustomobject]@{ language = $language; name = "" })
}

function Get-EndpointParts([string]$endpoint) {
    $uri = [System.Uri]$endpoint
    $hostName = $uri.Host.Trim('[', ']')
    $addresses = @()
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($hostName, [ref]$parsed)) {
        $addresses = @($parsed.ToString())
    } else {
        $addresses = [System.Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.ToString() }
    }
    return [pscustomobject]@{ Host = $hostName; Port = $uri.Port; Addresses = $addresses }
}

function Test-EngineListening([string]$endpoint) {
    $parts = Get-EndpointParts $endpoint
    foreach ($address in $parts.Addresses) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($address, $parts.Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(500) -and $client.Connected) { return $true }
        } catch {
        } finally {
            $client.Close()
        }
    }
    return $false
}

# M2b proof runs only. Starts the user's whisper.cpp server bound to the
# endpoint's own address and waits for the model to load.
function Start-ProofEngine([string]$endpoint, [string]$exe, [string]$model, [int]$timeoutSeconds = 90) {
    if (Test-EngineListening $endpoint) { throw "something already listens on $endpoint; refusing to start a second engine" }
    if (-not (Test-Path $exe)) { throw "engine executable not found: $exe" }
    if (-not (Test-Path $model)) { throw "engine model not found: $model" }
    $parts = Get-EndpointParts $endpoint
    # Viby sends an endpoint with no path to the OpenAI path (R3); serve the
    # path Viby will actually use.
    $path = ([System.Uri]$endpoint).AbsolutePath
    if (-not $path -or $path -eq "/") { $path = "/v1/audio/transcriptions" }
    $arguments = @("-m", "`"$model`"", "--host", $parts.Addresses[0], "--port", $parts.Port, "-l", "auto")
    if ($path -ne "/inference") { $arguments += @("--inference-path", $path) }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while (-not (Test-EngineListening $endpoint)) {
        if ($process.HasExited) { throw "the proof engine exited during startup (code $($process.ExitCode))" }
        if ((Get-Date) -gt $deadline) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "the proof engine did not listen on $endpoint within $timeoutSeconds s"
        }
        Start-Sleep -Milliseconds 500
    }
    return $process
}

function Stop-ProofEngine($process) {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
}

# The D23 replacement for the old "no TCP connections" assertion: Viby may
# hold connections, but only to the engine address it checked (R3a).
function Assert-EngineOnlyConnections([int]$vibyPid, [string]$endpoint, [string]$label) {
    $parts = Get-EndpointParts $endpoint
    $allowed = @($parts.Addresses) + @($parts.Addresses | ForEach-Object { "::ffff:$_" })
    $connections = @(Get-NetTCPConnection -OwningProcess $vibyPid -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne "Listen" -and $_.State -ne "Bound" })
    foreach ($connection in $connections) {
        if (($allowed -notcontains $connection.RemoteAddress) -or $connection.RemotePort -ne $parts.Port) {
            throw ("{0}: viby.exe connected to {1}:{2}, not the engine at {3}" -f
                $label, $connection.RemoteAddress, $connection.RemotePort, $endpoint)
        }
    }
    return $connections.Count
}
