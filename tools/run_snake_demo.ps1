param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 115200,
    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",
    [int]$RomAddrW = -1,
    [int]$WordsPerRow = -1,
    [int]$Rows = -1,
    [int]$RunCycles = 24000,
    [string]$OutDir = "build/snake_demo",
    [switch]$NoViewer
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$client = Join-Path $repoRoot "tools/hack_uart_client.py"
$vmPath = Join-Path $repoRoot "tools/programs/SnakeLite.vm"

foreach ($f in @($vmTool, $asmTool, $client, $vmPath)) {
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

$romDefault = if ($Profile -eq "sim_full") { 15 } else { 14 }
$wordsPerRowDefault = if ($Profile -eq "sim_full") { 32 } else { 8 }
$rowsDefault = if ($Profile -eq "sim_full") { 16 } else { 32 }
$screenWords = if ($Profile -eq "sim_full") { 8192 } else { 512 }

if (-not $PSBoundParameters.ContainsKey("RomAddrW")) {
    $RomAddrW = $romDefault
}
if (-not $PSBoundParameters.ContainsKey("WordsPerRow")) {
    $WordsPerRow = $wordsPerRowDefault
}
if (-not $PSBoundParameters.ContainsKey("Rows")) {
    $Rows = $rowsDefault
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$asmOut = Join-Path $outAbs "SnakeLite.asm"
$hack = Join-Path $outAbs "SnakeLite.hack"
$loadOut = Join-Path $outAbs "load"

function Invoke-UartClientWithRetry {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )
    $attempts = 8
    for ($n = 1; $n -le $attempts; $n++) {
        & $python.Source $client --port $Port --baud $Baud @Args
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($n -lt $attempts) {
            Start-Sleep -Milliseconds 250
            continue
        }
        throw "UART command failed after retries: $($Args -join ' ')"
    }
}

Write-Host "[INFO] Translating SnakeLite.vm -> ASM..."
& $python.Source $vmTool $vmPath -o $asmOut --bootstrap --sync-waits 2
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] VM translation failed"
    exit $LASTEXITCODE
}

Write-Host "[INFO] Assembling SnakeLite.asm -> HACK..."
& $python.Source $asmTool $asmOut -o $hack
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Assembly failed"
    exit $LASTEXITCODE
}

Write-Host "[INFO] Loading SnakeLite to FPGA over UART..."
Invoke-UartClientWithRetry `
    runhack `
    --hack-file $hack `
    --cycles 0 `
    --rom-addr-w $RomAddrW `
    --clear-ram-base 0 `
    --clear-ram-words 512 `
    --clear-screen-words $screenWords `
    --rom-verify `
    --out-dir $loadOut

if ($NoViewer) {
    Write-Host "[OK] SnakeLite loaded."
    Write-Host "Run viewer manually:"
    Write-Host "  python tools/hack_uart_client.py --port $Port --baud $Baud viewer --words-per-row $WordsPerRow --rows $Rows --auto-run --run-cycles $RunCycles --interval 0.08 --sticky-keys --no-delta --always-render --hard-clear-per-frame"
    Write-Host "Controls inside game: W/A/S/D or arrows (direction is latched until next key)"
    exit 0
}

Write-Host "[INFO] Starting SnakeLite viewer..."
Write-Host "Controls: W/A/S/D or arrows to steer, q=quit, space=run/pause, r=reset, s=state, x=key up"
Write-Host "Input mode: sticky keys (direction is held until you press another direction or x)"
& $python.Source $client `
    --port $Port `
    --baud $Baud `
    viewer `
    --words-per-row $WordsPerRow `
    --rows $Rows `
    --auto-run `
    --run-cycles $RunCycles `
    --interval 0.08 `
    --sticky-keys `
    --no-delta `
    --always-render `
    --hard-clear-per-frame
exit $LASTEXITCODE
