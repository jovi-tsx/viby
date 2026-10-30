Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    cargo tauri build --no-bundle
    $buildExit = $LASTEXITCODE
    Write-Output "BUILD_EXIT=$buildExit"
    if ($buildExit -ne 0) { exit $buildExit }

    if (Test-Path 'src-tauri\target\release\viby.exe') {
        $exe = Get-Item 'src-tauri\target\release\viby.exe'
        Write-Output "VIBY_EXE=$($exe.LastWriteTime.ToString('o'))"
    }
    exit $buildExit
} finally {
    Pop-Location
}
