param(
    [string]$JackInput = "tools/programs/JackSmokeSys.jack",
    [ValidateSet("sim_full", "fpga_fit")]
    [string]$Profile = "sim_full",
    [int]$Cycles = 200,
    [int]$ExpectAddr = 16,
    [int]$ExpectValue = 5,
    [string]$OutDir = "build/jack_pipeline",
    [switch]$Bootstrap,
    [switch]$NoBootstrap
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if ($Bootstrap -and $NoBootstrap) {
    throw "Use either -Bootstrap or -NoBootstrap, not both."
}

$jackTool = Join-Path $repoRoot "tools/hack_jack.py"
$vmPipe = Join-Path $repoRoot "tools/run_vm_pipeline_smoke.ps1"
$jackPath = if ([System.IO.Path]::IsPathRooted($JackInput)) { $JackInput } else { Join-Path $repoRoot $JackInput }

foreach ($f in @($jackTool, $vmPipe, $jackPath)) {
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
Write-Host "[INFO] Jack pipeline output: $outAbs"

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

$pipeArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $vmPipe,
    "-VmInput", $vmOut,
    "-Profile", $Profile,
    "-Cycles", "$Cycles",
    "-ExpectAddr", "$ExpectAddr",
    "-ExpectValue", "$ExpectValue",
    "-OutDir", (Join-Path $outAbs "vm_pipeline")
)
if ($Bootstrap) {
    $pipeArgs += "-Bootstrap"
} elseif ($NoBootstrap) {
    $pipeArgs += "-NoBootstrap"
} else {
    $pipeArgs += "-Bootstrap"
}

Write-Host "[INFO] Running VM pipeline smoke..."
powershell @pipeArgs
if ($LASTEXITCODE -ne 0) {
    throw "VM pipeline smoke failed"
}

Write-Host "[PASS] Jack pipeline smoke passed."
Write-Host "  Jack: $jackPath"
Write-Host "  VM  : $vmOut"
