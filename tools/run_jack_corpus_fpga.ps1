param(
    [Parameter(Mandatory = $true)]
    [string]$Port,
    [int]$Baud = 115200,
    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",
    [double]$TimeoutSec = 1.0,
    [string]$OutDir = "build/jack_corpus_fpga",
    [string[]]$Case = @(),
    [switch]$ContinueOnFailure,
    [switch]$Bootstrap,
    [switch]$NoBootstrap
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot "tools/run_jack_fpga_smoke.ps1"
$casesHelper = Join-Path $repoRoot "tools/jack_corpus_cases.ps1"

if ($Bootstrap -and $NoBootstrap) {
    throw "Use either -Bootstrap or -NoBootstrap, not both."
}

foreach ($required in @($runner, $casesHelper)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required script: $required"
    }
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

Write-Host "[INFO] Running Jack corpus on FPGA..."
Write-Host "[INFO] Port=$Port Baud=$Baud Profile=$Profile"
Write-Host "[INFO] Cases: $((($selected | ForEach-Object { $_.Name }) -join ', '))"

$failures = @()
$results = @()

foreach ($c in $selected) {
    $caseOut = Join-Path $outAbs $c.Name
    Write-Host ""
    Write-Host ("[CASE] {0}: expect RAM[0x{1:x4}] = 0x{2:x4}" -f $c.Name, $c.ExpectAddr, $c.ExpectValue)

    $caseArgs = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $runner,
        "-Port", $Port,
        "-Baud", "$Baud",
        "-Profile", $Profile,
        "-JackInput", $c.JackInput,
        "-Cycles", "$($c.Cycles)",
        "-ExpectAddr", "$($c.ExpectAddr)",
        "-ExpectValue", "$($c.ExpectValue)",
        "-TimeoutSec", "$TimeoutSec",
        "-OutDir", $caseOut
    )
    if ($Bootstrap) {
        $caseArgs += "-Bootstrap"
    } elseif ($NoBootstrap) {
        $caseArgs += "-NoBootstrap"
    } else {
        $caseArgs += "-Bootstrap"
    }

    powershell @caseArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Case failed: $($c.Name)"
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            ExpectAddr = $c.ExpectAddr
            ExpectValue = $c.ExpectValue
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) {
            break
        }
    } else {
        Write-Host "[PASS] Case passed: $($c.Name)"
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "PASS"
            ExpectAddr = $c.ExpectAddr
            ExpectValue = $c.ExpectValue
            OutDir = $caseOut
        }
    }
}

$summary = Join-Path $outAbs "summary.txt"
$summaryLines = @(
    "Jack corpus FPGA summary",
    "Port: $Port",
    "Baud: $Baud",
    "Profile: $Profile",
    "Cases requested: $($selected.Count)",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    ""
)
foreach ($r in $results) {
    $summaryLines += ("{0,-16} {1,-4} expect RAM[0x{2:x4}]=0x{3:x4}  out={4}" -f $r.Name, $r.Status, $r.ExpectAddr, $r.ExpectValue, $r.OutDir)
}
Set-Content -Path $summary -Value $summaryLines -Encoding ASCII

if ($failures.Count -gt 0) {
    Write-Host "[INFO] Summary: $summary"
    throw ("Jack corpus FPGA run failed. Failed cases: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Jack corpus FPGA run passed."
Write-Host "  Port   : $Port"
Write-Host "  Profile: $Profile"
Write-Host "  Cases  : $($selected.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
