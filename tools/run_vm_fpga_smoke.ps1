param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 115200,

    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",

    [string]$VmInput = "tools/programs/VmSmokeSys.vm",
    [int]$Cycles = 200,

    [int]$ExpectAddr = 5,
    [int]$ExpectValue = 5,

    [double]$TimeoutSec = 1.0,
    [string]$OutDir = "build/fpga_vm_smoke",

    [switch]$Bootstrap,
    [switch]$NoBootstrap
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if ($Bootstrap -and $NoBootstrap) {
    throw "Use either -Bootstrap or -NoBootstrap, not both."
}

$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$client = Join-Path $repoRoot "tools/hack_uart_client.py"
$budget = Join-Path $repoRoot "tools/check_profile_resource_budget.ps1"
$vmPath = if ([System.IO.Path]::IsPathRooted($VmInput)) { $VmInput } else { Join-Path $repoRoot $VmInput }

foreach ($f in @($vmTool, $asmTool, $client, $budget, $vmPath)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing required path: $f"
    }
}

$python = Get-Command python -ErrorAction Stop
$romAddrW = if ($Profile -eq "sim_full") { 15 } else { 14 }
$screenAddrW = if ($Profile -eq "sim_full") { 13 } else { 9 }
$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$asmOut = Join-Path $outAbs "program.asm"
$hackOut = Join-Path $outAbs "program.hack"
$runOut = Join-Path $outAbs "fpga_run"

$vmArgs = @($vmTool, $vmPath, "-o", $asmOut)
if ($Bootstrap) {
    $vmArgs += "--bootstrap"
} elseif ($NoBootstrap) {
    $vmArgs += "--no-bootstrap"
} else {
    $vmArgs += "--bootstrap"
}

Write-Host "[INFO] Translating VM -> ASM..."
& $python.Source @vmArgs
if ($LASTEXITCODE -ne 0) {
    throw "VM translation failed"
}

# Keep smoke deterministic: do not fall through into stale ROM contents.
@(
    "(VM_SMOKE_END)",
    "@VM_SMOKE_END",
    "0;JMP"
) | Add-Content -Path $asmOut -Encoding ASCII

Write-Host "[INFO] Assembling ASM -> HACK..."
& $python.Source $asmTool $asmOut -o $hackOut
if ($LASTEXITCODE -ne 0) {
    throw "Assembly failed"
}

$ramWindowWords = [Math]::Max(32, $ExpectAddr + 1)
Write-Host "[INFO] Verifying resource budgets..."
powershell -ExecutionPolicy Bypass -File $budget `
    -HackFile $hackOut `
    -Profile $Profile `
    -RomAddrW $romAddrW `
    -ScreenAddrW $screenAddrW `
    -RamBase 0 `
    -RamWords $ramWindowWords `
    -ScreenWords 1
if ($LASTEXITCODE -ne 0) {
    throw "Resource budget check failed"
}

$runArgs = @(
    $client,
    "--port", $Port,
    "--baud", "$Baud",
    "--timeout", "$TimeoutSec",
    "runhack",
    "--hack-file", $hackOut,
    "--cycles", "$Cycles",
    "--rom-addr-w", "$romAddrW",
    "--ram-base", "0",
    "--ram-words", "16",
    "--screen-words", "1",
    "--clear-ram-base", "0",
    "--clear-ram-words", "32",
    "--clear-screen-words", "1",
    "--rom-verify",
    "--rom-write-retries", "2",
    "--out-dir", $runOut
)

Write-Host "[INFO] Running translated program on FPGA..."
& $python.Source @runArgs
if ($LASTEXITCODE -ne 0) {
    throw "FPGA run failed"
}

Write-Host "[INFO] Checking RAM[0x$("{0:x4}" -f $ExpectAddr)] expected 0x$("{0:x4}" -f $ExpectValue)..."
$peek = & $python.Source $client --port $Port --baud $Baud --timeout $TimeoutSec peek ("0x{0:x}" -f $ExpectAddr)
if ($LASTEXITCODE -ne 0) {
    throw "peek failed at address $ExpectAddr"
}

$line = ($peek | Select-Object -First 1).Trim()
if ($line -notmatch "^0x([0-9a-fA-F]{1,4})$") {
    throw "unexpected peek output: $line"
}
$actual = [Convert]::ToInt32($matches[1], 16)

if ($actual -ne ($ExpectValue -band 0xFFFF)) {
    throw ("VM FPGA smoke failed: RAM[0x{0:x4}] = 0x{1:x4}, expected 0x{2:x4}" -f $ExpectAddr, $actual, ($ExpectValue -band 0xFFFF))
}

Write-Host "[PASS] VM FPGA smoke passed."
Write-Host "  VM   : $vmPath"
Write-Host "  ASM  : $asmOut"
Write-Host "  HACK : $hackOut"
Write-Host "  RAM  : [0x$("{0:x4}" -f $ExpectAddr)] = 0x$("{0:x4}" -f $actual)"
Write-Host "  Dump : $runOut"
