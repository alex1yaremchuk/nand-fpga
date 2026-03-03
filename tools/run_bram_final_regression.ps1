param(
    [string]$OutDir = "build/bram_final_regression",
    [string]$Port = "",
    [int]$Baud = 115200,
    [switch]$Fetch,
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

$runtimeSubsetCases = "Seven,ConvertToBin,Average,Square"
$project12CoreCases = "ArrayTest,MemoryTest,MathTest"
$steps = @()

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

$runtimeSubsetSimArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $repoRoot "tools/run_jack_official_runtime_fpga_subset_sim.ps1"),
    "-OutDir", (Join-Path $outAbs "jack_official_runtime_fpga_subset_sim"),
    "-Case", $runtimeSubsetCases
)
if ($Fetch) { $runtimeSubsetSimArgs += "-Fetch" }
$steps += @{
    Name = "Official Jack runtime fpga_fit subset (sim)"
    Args = $runtimeSubsetSimArgs
}

$project12CoreArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $repoRoot "tools/run_jack_project12_os_strict_smoke.ps1"),
    "-OutDir", (Join-Path $outAbs "jack_project12_os_strict_core"),
    "-Case", $project12CoreCases,
    "-CompactStringLiterals",
    "-VmSyncWaits", "1",
    "-ReportFpgaFitBudget",
    "-FailOnFpgaFitBudget"
)
if ($Fetch) { $project12CoreArgs += "-Fetch" }
$steps += @{
    Name = "Project 12 OS strict core (Array/Memory/Math) + fpga_fit budget gate"
    Args = $project12CoreArgs
}

if ($Port -ne "") {
    $runtimeSubsetHwArgs = @(
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $repoRoot "tools/run_jack_official_runtime_fpga_subset_hw.ps1"),
        "-Port", $Port,
        "-Baud", "$Baud",
        "-OutDir", (Join-Path $outAbs "jack_official_runtime_fpga_subset_hw"),
        "-Case", $runtimeSubsetCases
    )
    if ($Fetch) { $runtimeSubsetHwArgs += "-Fetch" }
    $steps += @{
        Name = "Official Jack runtime fpga_fit subset (hardware)"
        Args = $runtimeSubsetHwArgs
    }

    $steps += @{
        Name = "Golden compare strict (hardware)"
        Args = @(
            "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $repoRoot "tools/compare_fpga_uart_against_golden.ps1"),
            "-Port", $Port,
            "-Baud", "$Baud",
            "-Profile", "fpga_fit",
            "-StrictPcDump",
            "-OutDir", (Join-Path $outAbs "golden_compare_strict")
        )
    }

    $steps += @{
        Name = "Keyboard UART smoke (hardware)"
        Args = @(
            "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $repoRoot "tools/run_keyboard_uart_smoke.ps1"),
            "-Port", $Port,
            "-Baud", "$Baud",
            "-OutDir", (Join-Path $outAbs "keyboard_uart_smoke")
        )
    }
}

Write-Host "[INFO] Running BRAM final regression bundle..."
Write-Host "[INFO] Output: $outAbs"
Write-Host "[INFO] Runtime subset gate cases: $runtimeSubsetCases"
Write-Host "[INFO] Project12 core gate cases: $project12CoreCases"
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
    "BRAM final regression summary",
    "Output: $outAbs",
    "Hardware: $(if ($Port -ne '') { "enabled ($Port @ $Baud)" } else { "disabled" })",
    "Fetch: $Fetch",
    "Runtime subset gate cases: $runtimeSubsetCases",
    "Project12 core gate cases: $project12CoreCases",
    "FailFast: $FailFast",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "",
    "Known BRAM non-goals (not in this hard gate):",
    "- Project12 extended os_jack cases on fpga_fit ROM16K: String/Output/Screen/Sys/Keyboard",
    "- Runtime case ComplexArrays on fpga_fit ROM16K",
    ""
)
foreach ($r in $results) {
    $summaryLines += ("{0,-66} {1,-4} reason={2}" -f $r.Name, $r.Status, $r.Reason)
}
Set-Content -LiteralPath $summary -Value $summaryLines -Encoding ASCII

if ($failures.Count -gt 0) {
    Write-Host "[INFO] Summary: $summary"
    throw ("BRAM final regression failed. Failed steps: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] BRAM final regression passed."
Write-Host "  Steps  : $($results.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
