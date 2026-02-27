param(
    [string]$OutDir = "build/hack_runner_smoke"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot "tools/run_hack_runner.ps1"

if (-not (Test-Path -LiteralPath $runner)) {
    Write-Host "[ERROR] Missing runner script: $runner"
    exit 2
}

$tmpHack = Join-Path $env:TEMP ("hack-smoke-" + [guid]::NewGuid().ToString() + ".hack")

@(
    "0000000000010101",
    "1110110000010000",
    "0000000001100100",
    "1110001100001000",
    "0000000001100100",
    "1111110000010000"
) | Set-Content -Path $tmpHack -Encoding ASCII

try {
    powershell -ExecutionPolicy Bypass -File $runner `
        -HackFile $tmpHack `
        -Profile sim_full `
        -Cycles 6 `
        -RamBase 100 `
        -RamWords 1 `
        -ScreenWords 1 `
        -OutDir $OutDir

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] hack runner failed"
        exit $LASTEXITCODE
    }

    $outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
    $pcDump = Join-Path $outAbs "pc_dump.txt"
    $ramDump = Join-Path $outAbs "ram_dump.txt"

    if (-not (Test-Path -LiteralPath $pcDump) -or -not (Test-Path -LiteralPath $ramDump)) {
        Write-Host "[ERROR] Missing dump files in $outAbs"
        exit 2
    }

    $pcText = Get-Content -LiteralPath $pcDump -Raw
    $ramLine = (Get-Content -LiteralPath $ramDump | Select-Object -First 1)

    if ($pcText -notmatch "PC\s+6\b") {
        Write-Host "[ERROR] Unexpected PC in pc_dump.txt"
        exit 1
    }
    if ($pcText -notmatch "D\s+21\b") {
        Write-Host "[ERROR] Unexpected D in pc_dump.txt"
        exit 1
    }
    if ($ramLine -notmatch "\s0015$") {
        Write-Host "[ERROR] Unexpected RAM[100] in ram_dump.txt: $ramLine"
        exit 1
    }

    Write-Host "[OK] hack_runner smoke test passed."
    exit 0
}
finally {
    Remove-Item $tmpHack -ErrorAction SilentlyContinue
}
