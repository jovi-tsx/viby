Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'src-tauri')
try {
    Write-Output 'Running Rust unit tests...'
    cargo test --lib
    $testExit = $LASTEXITCODE
    Write-Output "TEST_EXIT=$testExit"
    if ($testExit -ne 0) { exit $testExit }

    Write-Output 'Running Clippy...'
    cargo clippy --all-targets -- -D warnings
    $clippyExit = $LASTEXITCODE
    Write-Output "CLIPPY_EXIT=$clippyExit"
    exit $clippyExit
} finally {
    Pop-Location
}
