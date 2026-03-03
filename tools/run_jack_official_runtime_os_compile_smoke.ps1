param(
    [string]$CorpusRoot = "",
    [string]$OsRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_official_runtime_os_compile_smoke",
    [string[]]$Case = @(),
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeSmoke = Join-Path $repoRoot "tools/run_jack_official_runtime_sim.ps1"

if (-not (Test-Path -LiteralPath $runtimeSmoke)) {
    throw "Missing script: $runtimeSmoke"
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$args = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $runtimeSmoke,
    "-OutDir", $outAbs,
    "-RuntimeMode", "os_jack",
    "-CheckMode", "compile"
)

if ($Fetch) { $args += "-Fetch" }
if ($ContinueOnFailure) { $args += "-ContinueOnFailure" }
if ($CorpusRoot -ne "") { $args += @("-CorpusRoot", $CorpusRoot) }
if ($OsRoot -ne "") { $args += @("-OsRoot", $OsRoot) }
if ($Case.Count -gt 0) { $args += @("-Case", $Case) }

Write-Host "[INFO] Running official Jack runtime OS compile smoke (RuntimeMode=os_jack, CheckMode=compile)..."
Write-Host "[INFO] Output: $outAbs"
powershell @args
exit $LASTEXITCODE
