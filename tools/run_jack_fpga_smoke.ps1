param(
    [Parameter(Mandatory = $true)]
    [string]$Port,
    [int]$Baud = 115200,
    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",
    [string]$JackInput = "tools/programs/JackSmokeSys.jack",
    [int]$Cycles = 200,
    [int]$ExpectAddr = 16,
    [int]$ExpectValue = 5,
    [double]$TimeoutSec = 1.0,
    [string]$OutDir = "build/jack_fpga_smoke",
    [switch]$Bootstrap,
    [switch]$NoBootstrap
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if ($Bootstrap -and $NoBootstrap) {
    throw "Use either -Bootstrap or -NoBootstrap, not both."
}

$jackTool = Join-Path $repoRoot "tools/hack_jack.py"
$vmFpga = Join-Path $repoRoot "tools/run_vm_fpga_smoke.ps1"
$jackPath = if ([System.IO.Path]::IsPathRooted($JackInput)) { $JackInput } else { Join-Path $repoRoot $JackInput }

foreach ($f in @($jackTool, $vmFpga, $jackPath)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing required path: $f"
    }
}

$python = Get-Command python -ErrorAction Stop
$outBase = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
if ($PSBoundParameters.ContainsKey("OutDir")) {
    $outAbs = $outBase
} else {
    $runId = ("run-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), $PID)
    $outAbs = Join-Path $outBase $runId
}
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null
Write-Host "[INFO] Jack FPGA smoke output: $outAbs"

$isDirInput = Test-Path -LiteralPath $jackPath -PathType Container
$vmOut = if ($isDirInput) { Join-Path $outAbs "vm" } else { Join-Path $outAbs "program.vm" }
if ($isDirInput) {
    New-Item -ItemType Directory -Force -Path $vmOut | Out-Null
}

Write-Host "[INFO] Compiling Jack -> VM..."
& $python.Source $jackTool $jackPath -o $vmOut
if ($LASTEXITCODE -ne 0) {
    throw "Jack compilation failed"
}

$fpgaArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $vmFpga,
    "-Port", $Port,
    "-Baud", "$Baud",
    "-Profile", $Profile,
    "-VmInput", $vmOut,
    "-Cycles", "$Cycles",
    "-ExpectAddr", "$ExpectAddr",
    "-ExpectValue", "$ExpectValue",
    "-TimeoutSec", "$TimeoutSec",
    "-OutDir", (Join-Path $outAbs "vm_fpga")
)
if ($Bootstrap) {
    $fpgaArgs += "-Bootstrap"
} elseif ($NoBootstrap) {
    $fpgaArgs += "-NoBootstrap"
} else {
    $fpgaArgs += "-Bootstrap"
}

Write-Host "[INFO] Running VM FPGA smoke..."
powershell @fpgaArgs
if ($LASTEXITCODE -ne 0) {
    throw "VM FPGA smoke failed"
}

Write-Host "[PASS] Jack FPGA smoke passed."
Write-Host "  Jack: $jackPath"
Write-Host "  VM  : $vmOut"
