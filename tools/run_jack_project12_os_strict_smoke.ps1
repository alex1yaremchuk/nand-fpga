param(
    [string]$CorpusRoot = "",
    [string]$OsRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_project12_os_strict_smoke",
    [string[]]$Case = @(),
    [switch]$IncludeStringTest,
    [switch]$IncludeExtendedTests,
    [switch]$CompactStringLiterals,
    [int]$VmSyncWaits = -1,
    [switch]$ReportFpgaFitBudget,
    [switch]$FailOnFpgaFitBudget,
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$apiSmoke = Join-Path $repoRoot "tools/run_jack_project12_api_smoke.ps1"

if (-not (Test-Path -LiteralPath $apiSmoke)) {
    throw "Missing script: $apiSmoke"
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null
if ($VmSyncWaits -lt -1) {
    throw "VmSyncWaits must be -1 (disabled) or >= 0, got $VmSyncWaits"
}

$args = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $apiSmoke,
    "-OutDir", $outAbs,
    "-RuntimeMode", "os_jack",
    "-CheckMode", "strict"
)

if ($Fetch) { $args += "-Fetch" }
if ($IncludeStringTest) { $args += "-IncludeStringTest" }
if ($IncludeExtendedTests) { $args += "-IncludeExtendedTests" }
if ($CompactStringLiterals) { $args += "-CompactStringLiterals" }
if ($VmSyncWaits -ge 0) { $args += @("-VmSyncWaits", "$VmSyncWaits") }
if ($ReportFpgaFitBudget) { $args += "-ReportFpgaFitBudget" }
if ($FailOnFpgaFitBudget) { $args += "-FailOnFpgaFitBudget" }
if ($ContinueOnFailure) { $args += "-ContinueOnFailure" }

if ($CorpusRoot -ne "") { $args += @("-CorpusRoot", $CorpusRoot) }
if ($OsRoot -ne "") { $args += @("-OsRoot", $OsRoot) }
if ($Case.Count -gt 0) { $args += @("-Case", $Case) }

Write-Host "[INFO] Running Project 12 OS strict smoke (RuntimeMode=os_jack, CheckMode=strict)..."
Write-Host "[INFO] Output: $outAbs"
Write-Host "[INFO] IncludeStringTest=$IncludeStringTest IncludeExtendedTests=$IncludeExtendedTests"
Write-Host "[INFO] CompactStringLiterals=$CompactStringLiterals VmSyncWaits=$VmSyncWaits"
Write-Host "[INFO] ReportFpgaFitBudget=$ReportFpgaFitBudget FailOnFpgaFitBudget=$FailOnFpgaFitBudget"
powershell @args
exit $LASTEXITCODE
