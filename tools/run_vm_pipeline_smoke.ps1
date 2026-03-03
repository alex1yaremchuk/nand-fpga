param(
    [Parameter(Mandatory = $true)]
    [string]$VmInput,
    [ValidateSet("sim_full", "fpga_fit")]
    [string]$Profile = "sim_full",
    [int]$Cycles = 20000,
    [string]$OutDir = "build/vm_pipeline",
    [int]$ExpectAddr = -1,
    [int]$ExpectValue = 0,
    [switch]$Bootstrap,
    [switch]$NoBootstrap
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")

if ($Bootstrap -and $NoBootstrap) {
    throw "Use either -Bootstrap or -NoBootstrap, not both."
}

$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$runner = Join-Path $repoRoot "tools/run_hack_runner.ps1"
$vmPath = Resolve-Path $VmInput -ErrorAction Stop

foreach ($f in @($vmTool, $asmTool, $runner, $vmPath)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing required path: $f"
    }
}

$python = Get-Command python -ErrorAction Stop
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$asmOut = Join-Path $OutDir "program.asm"
$hackOut = Join-Path $OutDir "program.hack"
$runnerOut = Join-Path $OutDir "runner"

$vmArgs = @($vmTool, $vmPath, "-o", $asmOut)
if ($Bootstrap) {
    $vmArgs += "--bootstrap"
}
elseif ($NoBootstrap) {
    $vmArgs += "--no-bootstrap"
}
else {
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
    throw "ASM translation failed"
}

Write-Host "[INFO] Running hack runner..."
$ramWords = if ($ExpectAddr -ge 0) { [Math]::Max(256, $ExpectAddr + 1) } else { 256 }
powershell -ExecutionPolicy Bypass -File $runner `
    -HackFile $hackOut `
    -Profile $Profile `
    -Cycles $Cycles `
    -RamBase 0 `
    -RamWords $ramWords `
    -OutDir $runnerOut
if ($LASTEXITCODE -ne 0) {
    throw "Hack runner failed"
}

if ($ExpectAddr -ge 0) {
    $ramDump = Join-Path $runnerOut "ram_dump.txt"
    if (-not (Test-Path -LiteralPath $ramDump)) {
        throw "Missing RAM dump: $ramDump"
    }

    $idx = "{0:x8}" -f $ExpectAddr
    $line = Get-Content -Path $ramDump | Where-Object { $_ -match ("^" + [regex]::Escape($idx) + "\s+") } | Select-Object -First 1
    if (-not $line) {
        throw "Expected RAM address not found in dump: 0x$("{0:x4}" -f $ExpectAddr)"
    }
    $parts = $line.Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -lt 2) {
        throw "Cannot parse RAM dump line: $line"
    }
    $actual = [Convert]::ToInt32($parts[1], 16)
    if ($actual -ne ($ExpectValue -band 0xFFFF)) {
        throw ("VM pipeline smoke failed: RAM[0x{0:x4}] = 0x{1:x4}, expected 0x{2:x4}" -f $ExpectAddr, $actual, ($ExpectValue -band 0xFFFF))
    }
    Write-Host "[INFO] RAM check passed: [0x$("{0:x4}" -f $ExpectAddr)] = 0x$("{0:x4}" -f $actual)"
}

Write-Host "[PASS] VM pipeline smoke passed"
Write-Host "  VM   : $vmPath"
Write-Host "  ASM  : $asmOut"
Write-Host "  HACK : $hackOut"
Write-Host "  Dump : $runnerOut"
