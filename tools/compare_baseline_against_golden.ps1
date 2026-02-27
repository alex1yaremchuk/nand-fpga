param(
    [ValidateSet("sim_full", "fpga_fit")]
    [string]$Profile = "sim_full",
    [string]$OutDir = "",
    [string]$GoldenDir = "tools/baseline_golden"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot "tools/run_baseline_program_tests.ps1"

if (-not (Test-Path -LiteralPath $runner)) {
    Write-Host "[ERROR] Missing script: $runner"
    exit 2
}

$runOut = $OutDir
if ($runOut -eq "") {
    if ($Profile -eq "sim_full") {
        $runOut = "build/baseline_tests"
    } else {
        $runOut = "build/baseline_tests_fpga_fit"
    }
}

$runOutAbs = if ([System.IO.Path]::IsPathRooted($runOut)) { $runOut } else { Join-Path $repoRoot $runOut }
$goldAbs = if ([System.IO.Path]::IsPathRooted($GoldenDir)) { $GoldenDir } else { Join-Path $repoRoot $GoldenDir }

if (-not (Test-Path -LiteralPath $goldAbs)) {
    Write-Host "[ERROR] Golden directory not found: $goldAbs"
    exit 2
}

Write-Host "[INFO] Running baseline tests for profile=$Profile ..."
powershell -ExecutionPolicy Bypass -File $runner -Profile $Profile -OutDir $runOutAbs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Baseline runner failed."
    exit $LASTEXITCODE
}

$tests = @("add", "max_case1", "max_case2", "rect")
$files = @("pc_dump.txt", "ram_dump.txt", "screen_dump.txt")

$diffs = @()
foreach ($t in $tests) {
    foreach ($f in $files) {
        $actual = Join-Path (Join-Path $runOutAbs $t) $f
        $gold = Join-Path (Join-Path $goldAbs $t) $f

        if (-not (Test-Path -LiteralPath $actual)) {
            $diffs += "missing actual: $actual"
            continue
        }
        if (-not (Test-Path -LiteralPath $gold)) {
            $diffs += "missing golden: $gold"
            continue
        }

        $a = Get-Content -LiteralPath $actual
        $g = Get-Content -LiteralPath $gold
        $cmp = Compare-Object -ReferenceObject $g -DifferenceObject $a -SyncWindow 0
        if ($cmp) {
            $diffs += "mismatch: $t/$f"
        }
    }
}

if ($diffs.Count -gt 0) {
    Write-Host "[ERROR] Baseline golden comparison failed:"
    $diffs | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host "[OK] Baseline outputs match golden artifacts."
exit 0
