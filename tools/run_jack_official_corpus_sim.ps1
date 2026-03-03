param(
    [string]$CorpusRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_official_corpus_sim",
    [string[]]$Case = @(),
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

$jackTool = Join-Path $repoRoot "tools/hack_jack.py"
$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$budgetTool = Join-Path $repoRoot "tools/check_profile_resource_budget.ps1"

foreach ($required in @($jackTool, $vmTool, $asmTool, $budgetTool)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required tool: $required"
    }
}

$defaultRepoRoot = Join-Path $repoRoot "build/_deps/n2t_projects"
$defaultCorpusRoot = Join-Path $defaultRepoRoot "projects/11"

if ($Fetch) {
    if (-not (Test-Path -LiteralPath $defaultRepoRoot)) {
        Write-Host "[INFO] Cloning nand2tetris/projects..."
        git clone --depth 1 https://github.com/nand2tetris/projects.git $defaultRepoRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone nand2tetris/projects"
        }
    } else {
        Write-Host "[INFO] Updating nand2tetris/projects..."
        git -C $defaultRepoRoot fetch --depth 1 origin
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch nand2tetris/projects"
        }
        $headRef = (git -C $defaultRepoRoot symbolic-ref refs/remotes/origin/HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $headRef) {
            $targetRef = $headRef.Trim()
        } else {
            $targetRef = "origin/main"
        }
        git -C $defaultRepoRoot reset --hard $targetRef
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to reset nand2tetris/projects to $targetRef"
        }
    }
}

if ($CorpusRoot -eq "") {
    $corpusAbs = $defaultCorpusRoot
} else {
    $corpusAbs = if ([System.IO.Path]::IsPathRooted($CorpusRoot)) { $CorpusRoot } else { Join-Path $repoRoot $CorpusRoot }
}

if (-not (Test-Path -LiteralPath $corpusAbs -PathType Container)) {
    throw "Official Jack corpus root not found: $corpusAbs`nUse -Fetch or pass -CorpusRoot."
}

$python = Get-Command python -ErrorAction Stop
$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$allCases = @("Average", "ComplexArrays", "ConvertToBin", "Pong", "Seven", "Square")

$selectedNames = $allCases
if ($Case.Count -gt 0) {
    $wanted = @{}
    foreach ($name in $Case) {
        $wanted[$name.ToLowerInvariant()] = $true
    }
    $selectedNames = @()
    foreach ($name in $allCases) {
        if ($wanted.ContainsKey($name.ToLowerInvariant())) {
            $selectedNames += $name
        }
    }
    if ($selectedNames.Count -eq 0) {
        throw ("No matching cases for -Case. Known cases: {0}" -f ($allCases -join ", "))
    }
}

Write-Host "[INFO] Running official Jack corpus compile pipeline (sim_full constraints)..."
Write-Host "[INFO] Corpus root: $corpusAbs"
Write-Host "[INFO] Cases: $($selectedNames -join ', ')"

$failures = @()
$results = @()

foreach ($name in $selectedNames) {
    $caseDir = Join-Path $corpusAbs $name
    if (-not (Test-Path -LiteralPath $caseDir -PathType Container)) {
        $failures += $name
        $results += [PSCustomObject]@{
            Name = $name
            Status = "FAIL"
            Reason = "Case directory missing"
            VmFiles = 0
            HackWords = 0
            OutDir = ""
        }
        if (-not $ContinueOnFailure) {
            break
        }
        continue
    }

    $jackFiles = Get-ChildItem -LiteralPath $caseDir -Filter *.jack -File
    if ($jackFiles.Count -eq 0) {
        $failures += $name
        $results += [PSCustomObject]@{
            Name = $name
            Status = "FAIL"
            Reason = "No .jack files found"
            VmFiles = 0
            HackWords = 0
            OutDir = ""
        }
        if (-not $ContinueOnFailure) {
            break
        }
        continue
    }

    $caseOut = Join-Path $outAbs $name
    $vmOut = Join-Path $caseOut "vm"
    $asmOut = Join-Path $caseOut "program.asm"
    $hackOut = Join-Path $caseOut "program.hack"
    New-Item -ItemType Directory -Force -Path $vmOut | Out-Null

    Write-Host ""
    Write-Host "[CASE] $name"

    & $python.Source $jackTool $caseDir -o $vmOut
    if ($LASTEXITCODE -ne 0) {
        $failures += $name
        $results += [PSCustomObject]@{
            Name = $name
            Status = "FAIL"
            Reason = "Jack -> VM failed"
            VmFiles = 0
            HackWords = 0
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) {
            break
        }
        continue
    }

    & $python.Source $vmTool $vmOut -o $asmOut --bootstrap
    if ($LASTEXITCODE -ne 0) {
        $failures += $name
        $results += [PSCustomObject]@{
            Name = $name
            Status = "FAIL"
            Reason = "VM -> ASM failed"
            VmFiles = (Get-ChildItem -LiteralPath $vmOut -Filter *.vm -File).Count
            HackWords = 0
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) {
            break
        }
        continue
    }

    & $python.Source $asmTool $asmOut -o $hackOut
    if ($LASTEXITCODE -ne 0) {
        $failures += $name
        $results += [PSCustomObject]@{
            Name = $name
            Status = "FAIL"
            Reason = "ASM -> HACK failed"
            VmFiles = (Get-ChildItem -LiteralPath $vmOut -Filter *.vm -File).Count
            HackWords = 0
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) {
            break
        }
        continue
    }

    powershell -ExecutionPolicy Bypass -File $budgetTool `
        -HackFile $hackOut `
        -Profile sim_full `
        -RomAddrW 15 `
        -ScreenAddrW 13 `
        -RamBase 0 `
        -RamWords 256 `
        -ScreenWords 8192
    if ($LASTEXITCODE -ne 0) {
        $failures += $name
        $results += [PSCustomObject]@{
            Name = $name
            Status = "FAIL"
            Reason = "sim_full budget check failed"
            VmFiles = (Get-ChildItem -LiteralPath $vmOut -Filter *.vm -File).Count
            HackWords = 0
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) {
            break
        }
        continue
    }

    $hackWords = (Get-Content -LiteralPath $hackOut | Where-Object { $_ -match '^[01]{16}$' }).Count
    $vmCount = (Get-ChildItem -LiteralPath $vmOut -Filter *.vm -File).Count
    $results += [PSCustomObject]@{
        Name = $name
        Status = "PASS"
        Reason = "ok"
        VmFiles = $vmCount
        HackWords = $hackWords
        OutDir = $caseOut
    }
    Write-Host ("[PASS] {0}: vm_files={1}, hack_words={2}" -f $name, $vmCount, $hackWords)
}

$summary = Join-Path $outAbs "summary.txt"
$summaryLines = @(
    "Official Jack corpus summary",
    "Corpus root: $corpusAbs",
    "Cases requested: $($selectedNames.Count)",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    ""
)
foreach ($r in $results) {
    $summaryLines += ("{0,-14} {1,-4} vm={2,-2} hack_words={3,-5} reason={4} out={5}" -f $r.Name, $r.Status, $r.VmFiles, $r.HackWords, $r.Reason, $r.OutDir)
}
Set-Content -LiteralPath $summary -Value $summaryLines -Encoding ASCII

if ($failures.Count -gt 0) {
    Write-Host "[INFO] Summary: $summary"
    throw ("Official Jack corpus pipeline failed. Failed cases: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Official Jack corpus pipeline passed."
Write-Host "  Cases  : $($selectedNames.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
