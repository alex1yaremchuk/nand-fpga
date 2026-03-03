param(
    [ValidateSet("sim_full", "fpga_fit")]
    [string]$Profile = "sim_full",
    [string]$OutDir = "build/jack_corpus_sim",
    [string[]]$Case = @(),
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot "tools/run_jack_pipeline_smoke.ps1"
$casesHelper = Join-Path $repoRoot "tools/jack_corpus_cases.ps1"

if (-not (Test-Path -LiteralPath $runner)) {
    throw "Missing required script: $runner"
}
if (-not (Test-Path -LiteralPath $casesHelper)) {
    throw "Missing required script: $casesHelper"
}

. $casesHelper

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$allCases = Get-JackCorpusCases -RepoRoot $repoRoot

foreach ($c in $allCases) {
    if (-not (Test-Path -LiteralPath $c.JackInput)) {
        throw "Missing Jack corpus case directory: $($c.JackInput)"
    }
}

$selected = $allCases
if ($Case.Count -gt 0) {
    $wanted = @{}
    foreach ($name in $Case) {
        $wanted[$name.ToLowerInvariant()] = $true
    }

    $selected = @()
    foreach ($c in $allCases) {
        if ($wanted.ContainsKey($c.Name.ToLowerInvariant())) {
            $selected += $c
        }
    }

    if ($selected.Count -eq 0) {
        $known = ($allCases | ForEach-Object { $_.Name }) -join ", "
        throw "No matching cases for -Case. Known cases: $known"
    }
}

Write-Host "[INFO] Running Jack corpus in profile '$Profile'..."
Write-Host "[INFO] Cases: $((($selected | ForEach-Object { $_.Name }) -join ', '))"

$failures = @()
foreach ($c in $selected) {
    $caseOut = Join-Path $outAbs $c.Name
    Write-Host ""
    Write-Host ("[CASE] {0}: expect RAM[0x{1:x4}] = 0x{2:x4}" -f $c.Name, $c.ExpectAddr, $c.ExpectValue)

    powershell -ExecutionPolicy Bypass -File $runner `
        -JackInput $c.JackInput `
        -Profile $Profile `
        -Cycles $c.Cycles `
        -ExpectAddr $c.ExpectAddr `
        -ExpectValue $c.ExpectValue `
        -Bootstrap `
        -OutDir $caseOut

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Case failed: $($c.Name)"
        $failures += $c.Name
        if (-not $ContinueOnFailure) {
            break
        }
    } else {
        Write-Host "[PASS] Case passed: $($c.Name)"
    }
}

if ($failures.Count -gt 0) {
    throw ("Jack corpus run failed. Failed cases: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Jack corpus run passed."
Write-Host "  Profile: $Profile"
Write-Host "  Cases  : $($selected.Count)"
Write-Host "  Output : $outAbs"
