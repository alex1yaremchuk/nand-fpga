param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 115200,
    [int]$RomAddrW = 14,
    [int]$Iterations = 40,
    [int]$PressCycles = 20,
    [int]$ReleaseCycles = 20,
    [string]$OutDir = "build/keyboard_uart_soak"
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

if ($Iterations -lt 1) {
    Write-Host "[ERROR] Iterations must be >= 1, got $Iterations"
    exit 2
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$hack = Join-Path $outAbs "KeyboardScreen.hack"
$loadOut = Join-Path $outAbs "load"

function Invoke-UartClient {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )
    $attempts = 6
    for ($n = 1; $n -le $attempts; $n++) {
        $out = & $python.Source $client --port $Port --baud $Baud @Args 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $out
        }

        $text = ($out | Out-String)
        if (($text -notmatch "Access is denied") -or ($n -eq $attempts)) {
            throw "UART client failed: $($Args -join ' ')`n$text"
        }
        Start-Sleep -Milliseconds 150
    }
}

function Read-U16Hex([string]$text) {
    if ($text -match "^0x([0-9a-fA-F]{4})$") {
        return [convert]::ToInt32($matches[1], 16)
    }
    throw "Unexpected hex word output: '$text'"
}

function Read-PeekWord([string]$addr) {
    $text = (Invoke-UartClient peek $addr | Select-Object -Last 1).Trim()
    return @{
        Text = $text
        Value = Read-U16Hex $text
    }
}

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

$keySeq = @(0x0041, 0x005A, 0x0031, 0x0080, 0x0082)
$checks = 0

Write-Host "[INFO] Running keyboard soak: iterations=$Iterations, keys=$($keySeq.Count)..."
for ($i = 0; $i -lt $Iterations; $i++) {
    $key = $keySeq[$i % $keySeq.Count]
    $keyHex = ("{0:X4}" -f $key)

    Invoke-UartClient kbd ("0x$keyHex") | Out-Null
    Invoke-UartClient run $PressCycles | Out-Null

    $ram0 = Read-PeekWord "0x0000"
    if ($ram0.Value -ne $key) {
        Write-Host "[ERROR] Iteration $($i + 1): expected RAM[0]=0x$keyHex, got $($ram0.Text)"
        exit 1
    }

    $screen0 = Read-PeekWord "0x4000"
    if ($screen0.Value -ne 0xFFFF) {
        Write-Host "[ERROR] Iteration $($i + 1): expected SCREEN[0]=0xFFFF during key press, got $($screen0.Text)"
        exit 1
    }

    Invoke-UartClient kbd 0x0000 | Out-Null
    Invoke-UartClient run $ReleaseCycles | Out-Null

    $ram0 = Read-PeekWord "0x0000"
    if ($ram0.Value -ne 0x0000) {
        Write-Host "[ERROR] Iteration $($i + 1): expected RAM[0]=0x0000 after key release, got $($ram0.Text)"
        exit 1
    }

    $screen0 = Read-PeekWord "0x4000"
    if ($screen0.Value -ne 0x0000) {
        Write-Host "[ERROR] Iteration $($i + 1): expected SCREEN[0]=0x0000 after key release, got $($screen0.Text)"
        exit 1
    }

    $checks += 2
    if ((($i + 1) % 10) -eq 0) {
        Write-Host "[INFO] Soak progress: $($i + 1)/$Iterations"
    }
}

Write-Host "[OK] Keyboard UART soak passed."
Write-Host "  Iterations: $Iterations"
Write-Host "  Transitions checked: $checks"
Write-Host "  Program : $hack"
Write-Host "  Load out: $loadOut"
exit 0
