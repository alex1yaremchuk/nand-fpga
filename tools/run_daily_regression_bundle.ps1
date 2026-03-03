param(
    [string]$OutDir = "build/daily_regression_bundle",
    [string]$Port = "",
    [int]$Baud = 115200,
    [switch]$Fetch,
    [switch]$Project12Extended,
    [switch]$FailOnFpgaFitBudgetOverflow,
    [switch]$FailFast
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    Write-Host ""
    Write-Host "[STEP] $Name"
    try {
        # Stream child script output to console but keep this function return value structured.
        powershell @Args | Out-Host
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{
                Name = $Name
                Status = "FAIL"
                Reason = "exit=$LASTEXITCODE"
            }
        }
        return [PSCustomObject]@{
            Name = $Name
            Status = "PASS"
            Reason = "ok"
        }
    } catch {
        return [PSCustomObject]@{
            Name = $Name
            Status = "FAIL"
            Reason = $_.Exception.Message
        }
    }
}

$steps = @()
$runtimeSubsetCases = "Seven,ConvertToBin,Average,Square"

$steps += @{
    Name = "Assembler unit tests"
    Args = @(
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $repoRoot "tools/run_hack_asm_tests.ps1"),
        "-OutDir", (Join-Path $outAbs "hack_asm_tests")
    )
}

$steps += @{
    Name = "VM translator unit tests"
    Args = @(
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $repoRoot "tools/run_hack_vm_tests.ps1"),
        "-OutDir", (Join-Path $outAbs "hack_vm_tests")
    )
}

$steps += @{
    Name = "Jack tokenizer unit tests"
    Args = @(
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $repoRoot "tools/run_hack_jack_tests.ps1"),
        "-OutDir", (Join-Path $outAbs "hack_jack_tests")
    )
}

$runtimeSubsetArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $repoRoot "tools/run_jack_official_runtime_fpga_subset_sim.ps1"),
    "-OutDir", (Join-Path $outAbs "jack_official_runtime_fpga_subset_sim"),
    "-Case", $runtimeSubsetCases
)
if ($Fetch) { $runtimeSubsetArgs += "-Fetch" }
$steps += @{
    Name = "Official Jack runtime fpga_fit subset (sim, pinned 4-case gate)"
    Args = $runtimeSubsetArgs
}

$project12StrictArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $repoRoot "tools/run_jack_project12_os_strict_smoke.ps1"),
    "-OutDir", (Join-Path $outAbs "jack_project12_os_strict")
)
if ($Project12Extended) {
    $project12StrictArgs += @(
        "-IncludeStringTest",
        "-IncludeExtendedTests",
        "-CompactStringLiterals",
        "-VmSyncWaits", "1",
        "-ReportFpgaFitBudget"
    )
    if ($FailOnFpgaFitBudgetOverflow) {
        $project12StrictArgs += "-FailOnFpgaFitBudget"
    }
} else {
    $project12StrictArgs += @(
        "-IncludeStringTest",
        "-Case", "ArrayTest,StringTest"
    )
}
if ($Fetch) { $project12StrictArgs += "-Fetch" }
$steps += @{
    Name = $(if ($Project12Extended) { "Project 12 OS strict full+extended (sim_full) + fpga_fit budget report" } else { "Project 12 OS strict subset (sim_full)" })
    Args = $project12StrictArgs
}

if ($Port -ne "") {
    $hwArgs = @(
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $repoRoot "tools/run_jack_official_runtime_fpga_subset_hw.ps1"),
        "-Port", $Port,
        "-Baud", "$Baud",
        "-OutDir", (Join-Path $outAbs "jack_official_runtime_fpga_subset_hw"),
        "-Case", $runtimeSubsetCases
    )
    if ($Fetch) { $hwArgs += "-Fetch" }
    $steps += @{
        Name = "Official Jack runtime fpga_fit subset (hardware, pinned 4-case gate)"
        Args = $hwArgs
    }
}

Write-Host "[INFO] Running daily regression bundle..."
Write-Host "[INFO] Output: $outAbs"
Write-Host "[INFO] Runtime subset gate cases: $runtimeSubsetCases"
Write-Host "[INFO] Project12Extended: $Project12Extended"
if ($Project12Extended) {
    Write-Host "[INFO] Project12 shrink knobs: CompactStringLiterals=true, VmSyncWaits=1"
}
Write-Host "[INFO] FailOnFpgaFitBudgetOverflow: $FailOnFpgaFitBudgetOverflow"
if ($Port -ne "") {
    Write-Host "[INFO] Hardware enabled: Port=$Port Baud=$Baud"
} else {
    Write-Host "[INFO] Hardware disabled (no -Port)."
}

$results = @()
$failures = @()
foreach ($step in $steps) {
    $r = Invoke-Step -Name $step.Name -Args $step.Args
    $results += $r
    if ($r.Status -ne "PASS") {
        $failures += $r.Name
        if ($FailFast) {
            break
        }
    }
}

$summary = Join-Path $outAbs "summary.txt"
$summaryLines = @(
    "Daily regression bundle summary",
    "Output: $outAbs",
    "Hardware: $(if ($Port -ne '') { "enabled ($Port @ $Baud)" } else { "disabled" })",
    "Fetch: $Fetch",
    "Project12Extended: $Project12Extended",
    "Project12 shrink knobs: $(if ($Project12Extended) { "CompactStringLiterals=true, VmSyncWaits=1" } else { "disabled" })",
    "FailOnFpgaFitBudgetOverflow: $FailOnFpgaFitBudgetOverflow",
    "Runtime subset gate cases: $runtimeSubsetCases",
    "FailFast: $FailFast",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    ""
)
foreach ($r in $results) {
    $summaryLines += ("{0,-55} {1,-4} reason={2}" -f $r.Name, $r.Status, $r.Reason)
}
Set-Content -LiteralPath $summary -Value $summaryLines -Encoding ASCII

if ($failures.Count -gt 0) {
    Write-Host "[INFO] Summary: $summary"
    throw ("Daily regression bundle failed. Failed steps: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Daily regression bundle passed."
Write-Host "  Steps  : $($results.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
