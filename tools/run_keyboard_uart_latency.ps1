param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 115200,
    [int]$RomAddrW = 14,
    [int]$Iterations = 40,
    [double]$P95ThresholdMs = 150,
    [int]$RunCyclesPerPoll = 1,
    [string]$OutDir = "build/keyboard_uart_latency"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$probe = Join-Path $repoRoot "tools/keyboard_latency_probe.py"
$asmPath = Join-Path $repoRoot "tools/programs/KeyboardScreen.asm"

foreach ($f in @($asmTool, $probe, $asmPath)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "[ERROR] Missing file: $f"
        exit 2
    }
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host "[ERROR] python not found in PATH"
    exit 3
}

if ($Iterations -lt 1) {
    Write-Host "[ERROR] Iterations must be >= 1, got $Iterations"
    exit 2
}
if ($RunCyclesPerPoll -lt 1) {
    Write-Host "[ERROR] RunCyclesPerPoll must be >= 1, got $RunCyclesPerPoll"
    exit 2
}
if ($P95ThresholdMs -le 0) {
    Write-Host "[ERROR] P95ThresholdMs must be > 0, got $P95ThresholdMs"
    exit 2
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$hack = Join-Path $outAbs "KeyboardScreen.hack"
$jsonOut = Join-Path $outAbs "latency_report.json"
$txtOut = Join-Path $outAbs "latency_report.txt"

Write-Host "[INFO] Assembling KeyboardScreen.asm..."
& $python.Source $asmTool $asmPath -o $hack
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Assembly failed"
    exit $LASTEXITCODE
}

Write-Host "[INFO] Running keyboard latency probe..."
& $python.Source $probe `
    --port $Port `
    --baud $Baud `
    --hack-file $hack `
    --rom-addr-w $RomAddrW `
    --iterations $Iterations `
    --run-cycles-per-poll $RunCyclesPerPoll `
    --p95-threshold-ms $P95ThresholdMs `
    --rom-verify `
    --enforce-threshold `
    --out-json $jsonOut `
    --out-report $txtOut
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Keyboard latency probe failed"
    exit $LASTEXITCODE
}

Write-Host "[OK] Keyboard UART latency gate passed."
Write-Host "  JSON  : $jsonOut"
Write-Host "  Report: $txtOut"
exit 0
