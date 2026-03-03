param(
    [string]$OutDir = "build/jack_runtime_extended_smoke",
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$runs = @(
    @{
        Name = "StringInt"
        Script = "tools/run_jack_string_runtime_smoke.ps1"
        Args = @("-OutDir", (Join-Path $outAbs "string"))
    },
    @{
        Name = "KeyboardInt"
        Script = "tools/run_jack_keyboard_runtime_smoke.ps1"
        Args = @("-OutDir", (Join-Path $outAbs "keyboard_int"))
    },
    @{
        Name = "KeyboardChar"
        Script = "tools/run_jack_keyboard_char_runtime_smoke.ps1"
        Args = @("-OutDir", (Join-Path $outAbs "keyboard_char"))
    }
)

$results = @()
$failures = @()

foreach ($run in $runs) {
    $scriptPath = Join-Path $repoRoot $run.Script
    $caseOut = $run.Args[1]
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Missing script: $scriptPath"
    }

    Write-Host ""
    Write-Host "[CASE] $($run.Name)"

    try {
        $cmd = @(
            "-ExecutionPolicy", "Bypass",
            "-File", $scriptPath
        ) + $run.Args
        powershell @cmd
        if ($LASTEXITCODE -ne 0) {
            throw ("exit code {0}" -f $LASTEXITCODE)
        }
        $results += [PSCustomObject]@{
            Name = $run.Name
            Status = "PASS"
            Reason = "ok"
            OutDir = $caseOut
        }
    } catch {
        $failures += $run.Name
        $results += [PSCustomObject]@{
            Name = $run.Name
            Status = "FAIL"
            Reason = $_.Exception.Message
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) {
            break
        }
    }
}

$summary = Join-Path $outAbs "summary.txt"
$summaryLines = @(
    "Jack runtime extended smoke summary (sim_full)",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    ""
)
foreach ($r in $results) {
    $summaryLines += ("{0,-14} {1,-4} reason={2} out={3}" -f $r.Name, $r.Status, $r.Reason, $r.OutDir)
}
Set-Content -LiteralPath $summary -Value $summaryLines -Encoding ASCII

if ($failures.Count -gt 0) {
    Write-Host "[INFO] Summary: $summary"
    throw ("Jack runtime extended smoke failed. Failed cases: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Jack runtime extended smoke passed."
Write-Host "  Cases  : $($results.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
