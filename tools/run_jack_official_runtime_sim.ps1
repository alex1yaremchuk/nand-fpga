param(
    [string]$CorpusRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_official_runtime_sim",
    [string[]]$Case = @(),
    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "sim_full",
    [string]$StubsRoot = "",
    [string]$OsRoot = "",
    [ValidateSet("stubs", "hybrid", "full", "os_jack")]
    [string]$RuntimeMode = "stubs",
    [ValidateSet("strict", "compile")]
    [string]$CheckMode = "strict",
    [int]$VmSyncWaits = 2,
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

$jackTool = Join-Path $repoRoot "tools/hack_jack.py"
$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$runnerTool = Join-Path $repoRoot "tools/run_hack_runner.ps1"
$budgetTool = Join-Path $repoRoot "tools/check_profile_resource_budget.ps1"
$stubsDir = if ($StubsRoot -eq "") {
    Join-Path $repoRoot "tools/programs/JackOfficialRuntimeStubs"
} else {
    if ([System.IO.Path]::IsPathRooted($StubsRoot)) { $StubsRoot } else { Join-Path $repoRoot $StubsRoot }
}

foreach ($required in @($jackTool, $vmTool, $asmTool, $runnerTool, $budgetTool, $stubsDir)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required path: $required"
    }
}

function New-RamInitFile {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )
    if ($Lines.Count -eq 0) {
        return ""
    }
    $path = Join-Path $env:TEMP ("jack-official-runtime-ram-init-" + [guid]::NewGuid().ToString() + ".txt")
    Set-Content -LiteralPath $path -Value $Lines -Encoding ASCII
    return $path
}

function Get-DumpValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DumpPath,
        [Parameter(Mandatory = $true)]
        [int]$Address
    )
    $idx = "{0:x8}" -f ($Address -band 0xFFFFFFFF)
    $line = Get-Content -LiteralPath $DumpPath | Where-Object { $_ -match ("^" + [regex]::Escape($idx) + "\s+") } | Select-Object -First 1
    if (-not $line) {
        throw "Address not found in dump: 0x$("{0:x4}" -f $Address) ($DumpPath)"
    }
    $parts = $line.Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -lt 2) {
        throw "Cannot parse dump line: $line"
    }
    return [Convert]::ToInt32($parts[1], 16)
}

function Assert-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [int]$Address,
        [Parameter(Mandatory = $true)]
        [int]$Actual,
        [Parameter(Mandatory = $true)]
        [hashtable]$Check
    )
    $mode = "eq"
    if ($Check.ContainsKey("Mode")) {
        $mode = ($Check.Mode.ToString()).ToLowerInvariant()
    }
    $expect = ($Check.Value -band 0xFFFF)

    switch ($mode) {
        "eq" {
            if ($Actual -ne $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected 0x{3:x4}" -f $Kind, $Address, $Actual, $expect)
            }
        }
        "ne" {
            if ($Actual -eq $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected != 0x{3:x4}" -f $Kind, $Address, $Actual, $expect)
            }
        }
        "ge" {
            if ($Actual -lt $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected >= 0x{3:x4}" -f $Kind, $Address, $Actual, $expect)
            }
        }
        "gt" {
            if ($Actual -le $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected > 0x{3:x4}" -f $Kind, $Address, $Actual, $expect)
            }
        }
        "le" {
            if ($Actual -gt $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected <= 0x{3:x4}" -f $Kind, $Address, $Actual, $expect)
            }
        }
        "lt" {
            if ($Actual -ge $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected < 0x{3:x4}" -f $Kind, $Address, $Actual, $expect)
            }
        }
        default {
            throw ("Unsupported check mode '{0}' for {1} at 0x{2:x4}" -f $mode, $Kind, $Address)
        }
    }
}

function Get-RuntimeClassFromVmFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmFile
    )
    $base = [System.IO.Path]::GetFileNameWithoutExtension($VmFile)
    if ($base.EndsWith("Lite")) {
        return $base.Substring(0, $base.Length - 4)
    }
    return $base
}

function Build-RuntimeVmMapFromJackDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RuntimeJackRoot,
        [Parameter(Mandatory = $true)]
        [string]$RuntimeVmOut,
        [Parameter(Mandatory = $true)]
        [object]$PythonCmd,
        [Parameter(Mandatory = $true)]
        [string]$JackCompiler,
        [Parameter(Mandatory = $true)]
        [string[]]$RuntimeClasses
    )

    New-Item -ItemType Directory -Force -Path $RuntimeVmOut | Out-Null
    Get-ChildItem -Path $RuntimeVmOut -Filter *.vm -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    $null = & $PythonCmd.Source $JackCompiler $RuntimeJackRoot -o $RuntimeVmOut
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile runtime Jack sources from $RuntimeJackRoot"
    }

    $map = @{}
    foreach ($cls in $RuntimeClasses) {
        $vmPath = Join-Path $RuntimeVmOut "$cls.vm"
        if (-not (Test-Path -LiteralPath $vmPath -PathType Leaf)) {
            throw "Compiled runtime VM missing class '$cls': $vmPath"
        }
        $map[$cls] = $vmPath
    }
    return $map
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

if ($VmSyncWaits -lt 0) {
    throw "VmSyncWaits must be >= 0, got $VmSyncWaits"
}

$romAddrW = if ($Profile -eq "sim_full") { 15 } else { 14 }
$screenAddrW = if ($Profile -eq "sim_full") { 13 } else { 9 }

$runtimeClassesAll = @("Sys", "Memory", "Array", "String", "Math", "Output", "Keyboard", "Screen")
$runtimeClassesHybridFull = @("Sys", "Memory", "Array", "String", "Math")
$runtimeVmMap = @{}
$runtimeSourceDesc = $stubsDir

if ($RuntimeMode -eq "os_jack") {
    $defaultOsRoot = Join-Path $defaultRepoRoot "projects/12"
    $osAbs = if ($OsRoot -eq "") {
        $defaultOsRoot
    } else {
        if ([System.IO.Path]::IsPathRooted($OsRoot)) { $OsRoot } else { Join-Path $repoRoot $OsRoot }
    }

    if (-not (Test-Path -LiteralPath $osAbs -PathType Container)) {
        throw "OS Jack source root not found: $osAbs"
    }
    foreach ($cls in $runtimeClassesAll) {
        $jackPath = Join-Path $osAbs "$cls.jack"
        if (-not (Test-Path -LiteralPath $jackPath -PathType Leaf)) {
            throw "Missing OS Jack source class '$cls': $jackPath"
        }
    }

    $runtimeVmOut = Join-Path $outAbs "_runtime_os_jack_vm"
    $runtimeVmMap = Build-RuntimeVmMapFromJackDir `
        -RuntimeJackRoot $osAbs `
        -RuntimeVmOut $runtimeVmOut `
        -PythonCmd $python `
        -JackCompiler $jackTool `
        -RuntimeClasses $runtimeClassesAll
    $runtimeSourceDesc = $osAbs
} else {
    foreach ($cls in $runtimeClassesAll) {
        $vmPath = Join-Path $stubsDir "$cls.vm"
        if (-not (Test-Path -LiteralPath $vmPath -PathType Leaf)) {
            throw "Runtime VM class missing in stubs pack: $vmPath"
        }
        $runtimeVmMap[$cls] = $vmPath
    }
}

$allCases = @(
    @{
        Name = "Seven"
        DirName = "Seven"
        SupportsRuntimeModes = @("stubs", "hybrid")
        Cycles = 12000
        RamBase = 3488
        RamWords = 32
        RamInit = @()
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "StringLite.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm")
        Checks = @(
            @{ Addr = 3500; Value = 7 }
        )
    },
    @{
        Name = "Average"
        DirName = "Average"
        SupportsRuntimeModes = @("stubs", "hybrid")
        Cycles = 90000
        RamBase = 2990
        RamWords = 1024
        JackArgs = @("--compact-string-literals")
        RamInit = @(
            "0bb8 0003", # 3000 = length
            "0bb9 000a", # 3001 = 10
            "0bba 0014", # 3002 = 20
            "0bbb 001e"  # 3003 = 30
        )
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "StringLite.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm")
        Checks = @(
            @{ Addr = 3500; Value = 20 },
            @{ Addr = 3700; Value = 84 } # 'T' from "The average is "
        )
    },
    @{
        Name = "ComplexArrays"
        DirName = "ComplexArrays"
        SupportsRuntimeModes = @("stubs", "hybrid")
        Cycles = 700000
        RamBase = 3496
        RamWords = 320
        RamInit = @()
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "StringLite.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm")
        Checks = @(
            @{ Addr = 3500; Value = 5 },
            @{ Addr = 3501; Value = 40 },
            @{ Addr = 3502; Value = 0 },
            @{ Addr = 3503; Value = 77 },
            @{ Addr = 3504; Value = 110 },
            @{ Addr = 3700; Value = 84 } # 'T' from "Test 1: ..."
        )
    },
    @{
        Name = "ConvertToBin"
        DirName = "ConvertToBin"
        SupportsRuntimeModes = @("stubs", "hybrid", "full")
        Cycles = 120000
        RamBase = 7998
        RamWords = 32
        # Hardware parity note: this case is sensitive to VM memory sync timing.
        # Keep a per-case override at 2 waits even when subset default is 1.
        VmArgs = @("--sync-waits", "2")
        RamInit = @(
            "1f40 000d"  # RAM[8000] = 13
        )
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "StringLite.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm")
        Checks = @(
            @{ Addr = 8001; Value = 1 },
            @{ Addr = 8002; Value = 0 },
            @{ Addr = 8003; Value = 1 },
            @{ Addr = 8004; Value = 1 },
            @{ Addr = 8005; Value = 0 },
            @{ Addr = 8016; Value = 0 }
        )
    },
    @{
        Name = "Square"
        DirName = "Square"
        SupportsRuntimeModes = @("stubs", "hybrid")
        Cycles = 180000
        RamBase = 3584
        RamWords = 96
        RamInit = @(
            "0c1c 0051", # Keyboard script: 'q'
            "0c1d 0000"  # release
        )
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "StringLite.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm", "Screen.vm")
        Checks = @(
            @{ Addr = 3600; Mode = "ge"; Value = 1 }
        )
        ScreenChecks = @(
            @{ Addr = 0; Mode = "ne"; Value = 0 }
        )
    },
    @{
        Name = "Pong"
        DirName = "Pong"
        SupportsRuntimeModes = @("stubs", "hybrid")
        Cycles = 260000
        RamBase = 3584
        RamWords = 160
        RamInit = @(
            "0c1c 008c", # Keyboard script: 140 (exit)
            "0c1d 0000"  # release
        )
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "StringLite.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm", "Screen.vm")
        Checks = @(
            @{ Addr = 3600; Mode = "ge"; Value = 1 }
        )
        ScreenChecks = @(
            @{ Addr = 0; Mode = "ne"; Value = 0 }
        )
    }
)

$selected = $allCases
if ($Case.Count -gt 0) {
    $wanted = @{}
    foreach ($name in $Case) {
        foreach ($part in ($name -split ",")) {
            $n = $part.Trim()
            if ($n -ne "") {
                $wanted[$n.ToLowerInvariant()] = $true
            }
        }
    }
    $selected = @()
    foreach ($c in $allCases) {
        if ($wanted.ContainsKey($c.Name.ToLowerInvariant()) -or $wanted.ContainsKey($c.DirName.ToLowerInvariant())) {
            $selected += $c
        }
    }
    if ($selected.Count -eq 0) {
        throw ("No matching cases for -Case. Known cases: {0}" -f (($allCases | ForEach-Object { $_.Name }) -join ", "))
    }
}

if ($RuntimeMode -eq "full") {
    $fullSupported = @()
    $fullUnsupported = @()
    foreach ($c in $selected) {
        if ($c.ContainsKey("SupportsRuntimeModes") -and ($c.SupportsRuntimeModes -contains "full")) {
            $fullSupported += $c
        } else {
            $fullUnsupported += $c.Name
        }
    }

    if ($fullUnsupported.Count -gt 0) {
        if ($Case.Count -gt 0) {
            throw ("RuntimeMode=full is not supported for cases: {0}. Try -RuntimeMode stubs|hybrid for these cases." -f (($fullUnsupported | Sort-Object -Unique) -join ", "))
        }
        if ($fullSupported.Count -eq 0) {
            throw "RuntimeMode=full has no compatible default cases."
        }
        Write-Host ("[WARN] RuntimeMode=full does not support some default cases; running only: {0}" -f (($fullSupported | ForEach-Object { $_.Name }) -join ", "))
        $selected = $fullSupported
    }
}

if (($RuntimeMode -eq "os_jack") -and ($CheckMode -eq "strict")) {
    throw "RuntimeMode=os_jack currently supports only -CheckMode compile. Use stubs|hybrid|full for strict behavioral checks."
}

Write-Host "[INFO] Running official Jack runtime smoke."
Write-Host "[INFO] Corpus root: $corpusAbs"
Write-Host "[INFO] Profile: $Profile"
Write-Host "[INFO] Runtime mode: $RuntimeMode"
Write-Host "[INFO] Check mode: $CheckMode"
Write-Host "[INFO] VM sync waits: $VmSyncWaits"
Write-Host "[INFO] Runtime source: $runtimeSourceDesc"
Write-Host "[INFO] Cases: $((($selected | ForEach-Object { $_.Name }) -join ', '))"

$failures = @()
$results = @()

foreach ($c in $selected) {
    $caseDir = Join-Path $corpusAbs $c.DirName
    $caseOut = Join-Path $outAbs $c.Name
    $vmOut = Join-Path $caseOut "vm"
    $asmOut = Join-Path $caseOut "program.asm"
    $hackOut = Join-Path $caseOut "program.hack"
    $runnerOut = Join-Path $caseOut "runner"
    New-Item -ItemType Directory -Force -Path $vmOut | Out-Null
    Get-ChildItem -Path $vmOut -Filter *.vm -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $caseDir -PathType Container)) {
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            Reason = "Case directory missing"
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) { break }
        continue
    }

    Write-Host ""
    Write-Host "[CASE] $($c.Name)"

    $jackArgs = @($jackTool, $caseDir, "-o", $vmOut)
    if ($c.ContainsKey("JackArgs") -and $c.JackArgs.Count -gt 0) {
        $jackArgs += @($c.JackArgs)
    }
    & $python.Source @jackArgs
    if ($LASTEXITCODE -ne 0) {
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            Reason = "Jack -> VM failed"
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) { break }
        continue
    }

    $stubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "StringLite.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm", "Screen.vm")
    if ($c.ContainsKey("StubFiles") -and $c.StubFiles.Count -gt 0) {
        $stubFiles = @($c.StubFiles)
    }
    if ($RuntimeMode -eq "stubs") {
        foreach ($stub in $stubFiles) {
            $stubPath = Join-Path $stubsDir $stub
            if (-not (Test-Path -LiteralPath $stubPath -PathType Leaf)) {
                throw "Missing stub VM file: $stubPath"
            }
            Copy-Item -Path $stubPath -Destination $vmOut -Force
        }
    } elseif ($RuntimeMode -eq "hybrid") {
        foreach ($cls in $runtimeClassesHybridFull) {
            Copy-Item -LiteralPath $runtimeVmMap[$cls] -Destination (Join-Path $vmOut "$cls.vm") -Force
        }
        foreach ($stub in $stubFiles) {
            $cls = Get-RuntimeClassFromVmFile -VmFile $stub
            if ($runtimeClassesHybridFull -contains $cls) {
                continue
            }
            $stubPath = Join-Path $stubsDir $stub
            if (-not (Test-Path -LiteralPath $stubPath -PathType Leaf)) {
                throw "Missing hybrid-mode stub VM file: $stubPath"
            }
            Copy-Item -Path $stubPath -Destination $vmOut -Force
        }
    } else {
        foreach ($cls in $runtimeClassesAll) {
            Copy-Item -LiteralPath $runtimeVmMap[$cls] -Destination (Join-Path $vmOut "$cls.vm") -Force
        }
    }

    $vmArgs = @($vmTool, $vmOut, "-o", $asmOut, "--bootstrap", "--sync-waits", $VmSyncWaits)
    if ($c.ContainsKey("VmArgs") -and $c.VmArgs.Count -gt 0) {
        $vmArgs += @($c.VmArgs)
    }
    & $python.Source @vmArgs
    if ($LASTEXITCODE -ne 0) {
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            Reason = "VM -> ASM failed"
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) { break }
        continue
    }

    & $python.Source $asmTool $asmOut -o $hackOut
    if ($LASTEXITCODE -ne 0) {
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            Reason = "ASM -> HACK failed"
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) { break }
        continue
    }

    powershell -ExecutionPolicy Bypass -File $budgetTool `
        -HackFile $hackOut `
        -Profile $Profile `
        -RomAddrW $romAddrW `
        -ScreenAddrW $screenAddrW `
        -RamBase $c.RamBase `
        -RamWords $c.RamWords `
        -ScreenWords 1
    if ($LASTEXITCODE -ne 0) {
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            Reason = "Budget check failed"
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) { break }
        continue
    }

    $ramInitPath = New-RamInitFile -Lines $c.RamInit
    try {
        $runnerArgs = @(
            "-ExecutionPolicy", "Bypass",
            "-File", $runnerTool,
            "-HackFile", $hackOut,
            "-Profile", $Profile,
            "-Cycles", "$($c.Cycles)",
            "-RamBase", "$($c.RamBase)",
            "-RamWords", "$($c.RamWords)",
            "-ScreenWords", "1",
            "-OutDir", $runnerOut
        )
        if ($ramInitPath -ne "") {
            $runnerArgs += @("-RamInitFile", $ramInitPath)
        }

        powershell @runnerArgs
        if ($LASTEXITCODE -ne 0) {
            throw "run_hack_runner failed"
        }

        $ramDump = Join-Path $runnerOut "ram_dump.txt"
        if (-not (Test-Path -LiteralPath $ramDump)) {
            throw "Missing RAM dump: $ramDump"
        }

        if ($CheckMode -eq "strict") {
            foreach ($check in $c.Checks) {
                $actual = Get-DumpValue -DumpPath $ramDump -Address $check.Addr
                Assert-Check -Kind "RAM" -Address $check.Addr -Actual $actual -Check $check
            }

            if ($c.ContainsKey("ScreenChecks") -and $c.ScreenChecks.Count -gt 0) {
                $screenDump = Join-Path $runnerOut "screen_dump.txt"
                if (-not (Test-Path -LiteralPath $screenDump)) {
                    throw "Missing SCREEN dump: $screenDump"
                }
                foreach ($check in $c.ScreenChecks) {
                    $actual = Get-DumpValue -DumpPath $screenDump -Address $check.Addr
                    Assert-Check -Kind "SCREEN" -Address $check.Addr -Actual $actual -Check $check
                }
            }
        }
    } catch {
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            Reason = $_.Exception.Message
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) { break }
        continue
    } finally {
        if (($ramInitPath -ne "") -and (Test-Path -LiteralPath $ramInitPath)) {
            Remove-Item -LiteralPath $ramInitPath -ErrorAction SilentlyContinue
        }
    }

    if ($CheckMode -eq "strict") {
        Write-Host "[PASS] $($c.Name) runtime check passed."
    } else {
        Write-Host "[PASS] $($c.Name) compile/run smoke passed (checks skipped)."
    }
    $results += [PSCustomObject]@{
        Name = $c.Name
        Status = "PASS"
        Reason = $(if ($CheckMode -eq "strict") { "ok" } else { "compile_only" })
        OutDir = $caseOut
    }
}

$summary = Join-Path $outAbs "summary.txt"
$summaryLines = @(
    "Official Jack runtime summary ($Profile)",
    "Corpus root: $corpusAbs",
    "Profile: $Profile",
    "Runtime mode: $RuntimeMode",
    "Check mode: $CheckMode",
    "VM sync waits: $VmSyncWaits",
    "Runtime source: $runtimeSourceDesc",
    "Cases requested: $($selected.Count)",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    ""
)
foreach ($r in $results) {
    $summaryLines += ("{0,-14} {1,-4} reason={2} out={3}" -f $r.Name, $r.Status, $r.Reason, $r.OutDir)
}
Set-Content -LiteralPath $summary -Value $summaryLines -Encoding ASCII

if ($failures.Count -gt 0) {
    Write-Host "[INFO] Summary: $summary"
    throw ("Official Jack runtime smoke failed. Failed cases: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Official Jack runtime smoke passed."
Write-Host "  Cases  : $($selected.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
