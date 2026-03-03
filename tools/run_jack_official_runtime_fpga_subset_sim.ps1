param(
    [string]$CorpusRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_official_runtime_fpga_subset",
    [string[]]$Case = @(),
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeSmoke = Join-Path $repoRoot "tools/run_jack_official_runtime_sim.ps1"
$subsetStubsRoot = Join-Path $repoRoot "tools/programs/JackOfficialRuntimeFpgaSubsetStubs"

if (-not (Test-Path -LiteralPath $runtimeSmoke)) {
    throw "Missing script: $runtimeSmoke"
}
if (-not (Test-Path -LiteralPath $subsetStubsRoot -PathType Container)) {
    throw "Missing fpga subset stubs root: $subsetStubsRoot"
}

$defaultCases = @("Seven", "ConvertToBin", "Average", "Square")
$casesToRun = if ($Case.Count -gt 0) { $Case } else { $defaultCases }

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$args = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $runtimeSmoke,
    "-OutDir", $outAbs,
    "-Profile", "fpga_fit",
    "-StubsRoot", $subsetStubsRoot,
    "-RuntimeMode", "stubs",
    "-CheckMode", "strict",
    "-VmSyncWaits", "1",
    "-Case", ($casesToRun -join ",")
)

if ($Fetch) { $args += "-Fetch" }
if ($ContinueOnFailure) { $args += "-ContinueOnFailure" }
if ($CorpusRoot -ne "") { $args += @("-CorpusRoot", $CorpusRoot) }

Write-Host "[INFO] Running official Jack runtime fpga_fit subset (sim smoke)..."
Write-Host "[INFO] Cases: $($casesToRun -join ', ')"
Write-Host "[INFO] Output: $outAbs"
powershell @args
exit $LASTEXITCODE
