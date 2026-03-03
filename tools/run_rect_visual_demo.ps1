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
$rectAsm = Join-Path $repoRoot "tools/programs/RectCanonical.asm"

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

$hack = Join-Path $outAbs "RectCanonical.hack"
$ramInit = Join-Path $outAbs "rect_canonical_ram_init.txt"
& $python.Source $asm $rectAsm -o $hack
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Assembly failed"
    exit $LASTEXITCODE
}

if ($Profile -eq "fpga_fit") {
    $screenWords = 512   # 128x64 px = 8 words/row * 64 rows
    $rectStride = 8
    $rectHeight = 16
    $wordsPerRow = 8
    $rows = 64
    $previewRows = 12
} else {
    $screenWords = 8192
    $rectStride = 32
    $rectHeight = 16
    $wordsPerRow = 32
    $rows = 256
    $previewRows = 8
}

@(
    ("{0:X4} {1:X4}" -f 0, $rectHeight),
    ("{0:X4} {1:X4}" -f 1, $rectStride)
) | Set-Content -Path $ramInit -Encoding ASCII

powershell -ExecutionPolicy Bypass -File $runner `
    -HackFile $hack `
    -Profile $Profile `
    -Cycles 400 `
    -RamInitFile $ramInit `
    -RamBase 0 `
    -RamWords 2 `
    -ScreenWords $screenWords `
    -OutDir $outAbs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Simulation failed"
    exit $LASTEXITCODE
}

$screenDump = Join-Path $outAbs "screen_dump.txt"
$pbm = Join-Path $outAbs "screen.pbm"

& $python.Source $render $screenDump -o $pbm --words-per-row $wordsPerRow --rows $rows --preview --preview-rows $previewRows
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Render failed"
    exit $LASTEXITCODE
}

Write-Host "[OK] Rect visual demo complete."
Write-Host "  Dump : $screenDump"
Write-Host "  PBM  : $pbm"
exit 0
