param(
    [ValidateSet("sim_full", "fpga_fit")]
    [string]$Profile = "fpga_fit",
    [string]$OutDir = "build/rect_visual_demo"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$asm = Join-Path $repoRoot "tools/hack_asm.py"
$runner = Join-Path $repoRoot "tools/run_hack_runner.ps1"
$render = Join-Path $repoRoot "tools/render_screen_dump.py"
$rectAsm = Join-Path $repoRoot "tools/programs/Rect.asm"

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host "[ERROR] python not found in PATH"
    exit 3
}

foreach ($f in @($asm, $runner, $render, $rectAsm)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "[ERROR] Missing file: $f"
        exit 2
    }
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$hack = Join-Path $outAbs "Rect.hack"
& $python.Source $asm $rectAsm -o $hack
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Assembly failed"
    exit $LASTEXITCODE
}

powershell -ExecutionPolicy Bypass -File $runner `
    -HackFile $hack `
    -Profile $Profile `
    -Cycles 40 `
    -RamBase 0 `
    -RamWords 1 `
    -ScreenWords 256 `
    -OutDir $outAbs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Simulation failed"
    exit $LASTEXITCODE
}

$screenDump = Join-Path $outAbs "screen_dump.txt"
$pbm = Join-Path $outAbs "screen.pbm"

& $python.Source $render $screenDump -o $pbm --words-per-row 32 --rows 8 --preview --preview-rows 4
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Render failed"
    exit $LASTEXITCODE
}

Write-Host "[OK] Rect visual demo complete."
Write-Host "  Dump : $screenDump"
Write-Host "  PBM  : $pbm"
exit 0
