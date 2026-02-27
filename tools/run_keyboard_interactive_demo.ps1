param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 115200,
    [int]$RomAddrW = 13,
    [int]$WordsPerRow = 8,
    [int]$Rows = 8,
    [string]$OutDir = "build/keyboard_interactive_demo",
    [switch]$NoViewer
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$client = Join-Path $repoRoot "tools/hack_uart_client.py"
$asmPath = Join-Path $repoRoot "tools/programs/KeyboardScreen.asm"

foreach ($f in @($asmTool, $client, $asmPath)) {
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

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$hack = Join-Path $outAbs "KeyboardScreen.hack"
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
            Start-Sleep -Milliseconds 200
            continue
        }
        throw "UART command failed after retries: $($Args -join ' ')"
    }
}

Write-Host "[INFO] Assembling KeyboardScreen.asm..."
& $python.Source $asmTool $asmPath -o $hack
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Assembly failed"
    exit $LASTEXITCODE
}

Write-Host "[INFO] Loading program to FPGA over UART..."
Invoke-UartClientWithRetry `
    runhack `
    --hack-file $hack `
    --cycles 0 `
    --rom-addr-w $RomAddrW `
    --clear-ram-base 0 `
    --clear-ram-words 16 `
    --clear-screen-words 256 `
    --rom-verify `
    --out-dir $loadOut

if ($NoViewer) {
    Write-Host "[OK] Program loaded."
    Write-Host "Run viewer manually:"
    Write-Host "  python tools/hack_uart_client.py --port $Port --baud $Baud viewer --words-per-row $WordsPerRow --rows $Rows --auto-run"
    exit 0
}

Write-Host "[INFO] Starting interactive viewer..."
Write-Host "Controls: q=quit, space=run/pause, r=reset, s=state, x=key up"
& $python.Source $client `
    --port $Port `
    --baud $Baud `
    viewer `
    --words-per-row $WordsPerRow `
    --rows $Rows `
    --auto-run
exit $LASTEXITCODE
