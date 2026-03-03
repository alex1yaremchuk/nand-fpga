param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 115200,
    [int]$RomAddrW = 14,
    [int]$SoakIterations = 40,
    [int]$LatencyIterations = 40,
    [double]$LatencyP95Ms = 150,
    [switch]$SkipLatency,
    [switch]$SkipProtocolDiag,
    [switch]$SkipSoak,
    [string]$OutDir = "build/keyboard_uart_smoke"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$client = Join-Path $repoRoot "tools/hack_uart_client.py"
$asmPath = Join-Path $repoRoot "tools/programs/KeyboardScreen.asm"
$soakScript = Join-Path $repoRoot "tools/run_keyboard_uart_soak.ps1"
$latencyScript = Join-Path $repoRoot "tools/run_keyboard_uart_latency.ps1"

foreach ($f in @($asmTool, $client, $asmPath, $soakScript, $latencyScript)) {
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

Write-Host "[INFO] Assembling KeyboardScreen.asm..."
& $python.Source $asmTool $asmPath -o $hack
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Assembly failed"
    exit $LASTEXITCODE
}

Write-Host "[INFO] Loading program via UART..."
& $python.Source $client `
    --port $Port `
    --baud $Baud `
    runhack `
    --hack-file $hack `
    --cycles 0 `
    --rom-addr-w $RomAddrW `
    --clear-ram-base 0 `
    --clear-ram-words 16 `
    --clear-screen-words 16 `
    --rom-verify `
    --out-dir $loadOut
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Program load failed"
    exit $LASTEXITCODE
}

function Invoke-UartClient {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )
    $attempts = 5
    for ($n = 1; $n -le $attempts; $n++) {
        $out = & $python.Source $client --port $Port --baud $Baud @Args 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $out
        }

        $text = ($out | Out-String)
        if ($text -notmatch "Access is denied") {
            throw "UART client failed: $($Args -join ' ')`n$text"
        }

        if ($n -lt $attempts) {
            Start-Sleep -Milliseconds 150
            continue
        }
        throw "UART client failed (port busy): $($Args -join ' ')`n$text"
    }
}

function Read-U16Hex([string]$text) {
    if ($text -match "^0x([0-9a-fA-F]{4})$") {
        return [convert]::ToInt32($matches[1], 16)
    }
    throw "Unexpected hex word output: '$text'"
}

function Get-UartDiag {
    $text = (Invoke-UartClient diag --json | Select-Object -Last 1).Trim()
    try {
        $obj = $text | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse diag JSON: '$text'"
    }
    return @{
        RxErr = [int]$obj.rx_err
        Desync = [int]$obj.desync
        Unknown = [int]$obj.unknown_cmd
        Retry = [int]$obj.retry_count
    }
}

function Get-CounterDelta([int]$start, [int]$end) {
    if ($end -ge $start) {
        return ($end - $start)
    }
    return (65536 - $start + $end)
}

Write-Host "[INFO] Running keyboard behavior checks..."

$diagStart = $null
if (-not $SkipProtocolDiag) {
    $diagStart = Get-UartDiag
    Write-Host ("[INFO] Protocol diag start: rx_err={0} desync={1} unknown={2}" -f `
        $diagStart.RxErr, $diagStart.Desync, $diagStart.Unknown)
}

# Baseline: no key -> screen[0] must be 0.
Invoke-UartClient run 20 | Out-Null
$screen0Text = (Invoke-UartClient peek 0x4000 | Select-Object -Last 1).Trim()
$screen0 = Read-U16Hex $screen0Text
if ($screen0 -ne 0x0000) {
    Write-Host "[ERROR] Expected SCREEN[0]=0x0000 at idle, got $screen0Text"
    exit 1
}

# Press 'A' (0x41): program should mirror key to RAM[0] and set screen[0]=ffff.
Invoke-UartClient kbd 0x0041 | Out-Null
Invoke-UartClient run 20 | Out-Null
$ram0Text = (Invoke-UartClient peek 0x0000 | Select-Object -Last 1).Trim()
$ram0 = Read-U16Hex $ram0Text
if ($ram0 -ne 0x0041) {
    Write-Host "[ERROR] Expected RAM[0]=0x0041 after key press, got $ram0Text"
    exit 1
}
$screen0Text = (Invoke-UartClient peek 0x4000 | Select-Object -Last 1).Trim()
$screen0 = Read-U16Hex $screen0Text
if ($screen0 -ne 0xFFFF) {
    Write-Host "[ERROR] Expected SCREEN[0]=0xFFFF while key pressed, got $screen0Text"
    exit 1
}

# Release key: screen should return to 0.
Invoke-UartClient kbd 0x0000 | Out-Null
Invoke-UartClient run 20 | Out-Null
$screen0Text = (Invoke-UartClient peek 0x4000 | Select-Object -Last 1).Trim()
$screen0 = Read-U16Hex $screen0Text
if ($screen0 -ne 0x0000) {
    Write-Host "[ERROR] Expected SCREEN[0]=0x0000 after key release, got $screen0Text"
    exit 1
}

Write-Host "[OK] Keyboard UART smoke passed."
Write-Host "  Program : $hack"
Write-Host "  Load out: $loadOut"

if (-not $SkipSoak) {
    Write-Host "[INFO] Running keyboard soak gate..."
    $soakOut = Join-Path $outAbs "soak"
    powershell -ExecutionPolicy Bypass -File $soakScript `
        -Port $Port `
        -Baud $Baud `
        -RomAddrW $RomAddrW `
        -Iterations $SoakIterations `
        -OutDir $soakOut
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Keyboard soak gate failed"
        exit $LASTEXITCODE
    }
}

if (-not $SkipLatency) {
    Write-Host "[INFO] Running keyboard latency gate..."
    $latOut = Join-Path $outAbs "latency"
    powershell -ExecutionPolicy Bypass -File $latencyScript `
        -Port $Port `
        -Baud $Baud `
        -RomAddrW $RomAddrW `
        -Iterations $LatencyIterations `
        -P95ThresholdMs $LatencyP95Ms `
        -OutDir $latOut
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Keyboard latency gate failed"
        exit $LASTEXITCODE
    }
}

if (-not $SkipProtocolDiag) {
    $diagEnd = Get-UartDiag
    $dRxErr = Get-CounterDelta $diagStart.RxErr $diagEnd.RxErr
    $dDesync = Get-CounterDelta $diagStart.Desync $diagEnd.Desync
    $dUnknown = Get-CounterDelta $diagStart.Unknown $diagEnd.Unknown

    Write-Host ("[INFO] Protocol diag delta: d_rx_err={0} d_desync={1} d_unknown={2}" -f `
        $dRxErr, $dDesync, $dUnknown)

    if (($dRxErr -ne 0) -or ($dDesync -ne 0) -or ($dUnknown -ne 0)) {
        Write-Host "[ERROR] Protocol diagnostics gate failed (expected zero deltas)."
        exit 1
    }
}

exit 0
