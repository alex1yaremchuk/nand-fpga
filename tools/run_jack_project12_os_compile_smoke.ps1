param(
    [string]$CorpusRoot = "",
    [string]$OsRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_project12_os_compile_smoke",
    [string[]]$Case = @(),
    [switch]$IncludeStringTest,
    [switch]$IncludeExtendedTests,
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

$args = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $apiSmoke,
    "-OutDir", $outAbs,
    "-RuntimeMode", "os_jack",
    "-CheckMode", "compile"
)

if ($Fetch) { $args += "-Fetch" }
if ($IncludeStringTest) { $args += "-IncludeStringTest" }
if ($IncludeExtendedTests) { $args += "-IncludeExtendedTests" }
if ($ContinueOnFailure) { $args += "-ContinueOnFailure" }

if ($CorpusRoot -ne "") { $args += @("-CorpusRoot", $CorpusRoot) }
if ($OsRoot -ne "") { $args += @("-OsRoot", $OsRoot) }
if ($Case.Count -gt 0) { $args += @("-Case", $Case) }

Write-Host "[INFO] Running Project 12 OS compile smoke (RuntimeMode=os_jack, CheckMode=compile)..."
Write-Host "[INFO] Output: $outAbs"
powershell @args
exit $LASTEXITCODE
