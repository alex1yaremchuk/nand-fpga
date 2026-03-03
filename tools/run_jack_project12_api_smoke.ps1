param(
    [string]$CorpusRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_project12_api_smoke",
    [string[]]$Case = @(),
    [switch]$IncludeStringTest,
    [switch]$IncludeExtendedTests,
    [string]$OsRoot = "",
    [ValidateSet("stubs", "hybrid", "full", "os_jack")]
    [string]$RuntimeMode = "stubs",
    [ValidateSet("strict", "compile")]
    [string]$CheckMode = "strict",
    [switch]$CompactStringLiterals,
    [int]$VmSyncWaits = -1,
    [switch]$ReportFpgaFitBudget,
    [switch]$FailOnFpgaFitBudget,
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

$jackTool = Join-Path $repoRoot "tools/hack_jack.py"
$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$runnerTool = Join-Path $repoRoot "tools/run_hack_runner.ps1"
$budgetTool = Join-Path $repoRoot "tools/check_profile_resource_budget.ps1"
$stubsDir = Join-Path $repoRoot "tools/programs/JackOfficialRuntimeStubs"
$defaultOsJackRuntimeDir = Join-Path $repoRoot "tools/programs/JackOfficialRuntimeJack"

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
    $path = Join-Path $env:TEMP ("jack-project12-api-ram-init-" + [guid]::NewGuid().ToString() + ".txt")
    Set-Content -LiteralPath $path -Value $Lines -Encoding ASCII
    return $path
}

function Get-DumpMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DumpPath
    )
    if (-not (Test-Path -LiteralPath $DumpPath)) {
        throw "Dump file not found: $DumpPath"
    }

    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $DumpPath)) {
        $parts = $line.Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Count -lt 2) {
            continue
        }
        try {
            $addr = [Convert]::ToInt32($parts[0], 16)
            $value = [Convert]::ToInt32($parts[1], 16)
            $map[$addr] = $value
        } catch {
            continue
        }
    }
    return $map
}

function Get-DumpValueFromMap {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,
        [Parameter(Mandatory = $true)]
        [int]$Address
    )
    if (-not $Map.ContainsKey($Address)) {
        throw "Address not found in dump map: 0x$("{0:x4}" -f $Address)"
    }
    return ([int]$Map[$Address] -band 0xFFFF)
}

function Assert-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,
        [Parameter(Mandatory = $true)]
        [hashtable]$Check
    )
    $addr = [int]$Check.Addr
    $actual = Get-DumpValueFromMap -Map $Map -Address $addr
    $expect = ([int]$Check.Value -band 0xFFFF)
    $mode = "eq"
    if ($Check.ContainsKey("Mode")) {
        $mode = ($Check.Mode.ToString()).ToLowerInvariant()
    }

    switch ($mode) {
        "eq" {
            if ($actual -ne $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected 0x{3:x4}" -f $Kind, $addr, $actual, $expect)
            }
        }
        "ne" {
            if ($actual -eq $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected != 0x{3:x4}" -f $Kind, $addr, $actual, $expect)
            }
        }
        "ge" {
            if ($actual -lt $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected >= 0x{3:x4}" -f $Kind, $addr, $actual, $expect)
            }
        }
        "gt" {
            if ($actual -le $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected > 0x{3:x4}" -f $Kind, $addr, $actual, $expect)
            }
        }
        "le" {
            if ($actual -gt $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected <= 0x{3:x4}" -f $Kind, $addr, $actual, $expect)
            }
        }
        "lt" {
            if ($actual -ge $expect) {
                throw ("{0} mismatch at 0x{1:x4}: got 0x{2:x4}, expected < 0x{3:x4}" -f $Kind, $addr, $actual, $expect)
            }
        }
        default {
            throw ("Unsupported check mode '{0}' for {1} at 0x{2:x4}" -f $mode, $Kind, $addr)
        }
    }
}

function Test-AsciiContains {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,
        [Parameter(Mandatory = $true)]
        [int]$Start,
        [Parameter(Mandatory = $true)]
        [int]$Length,
        [Parameter(Mandatory = $true)]
        [string]$Text
    )
    if ($Length -le 0) {
        return $false
    }
    $chars = $Text.ToCharArray()
    if ($chars.Count -eq 0) {
        return $true
    }
    if ($chars.Count -gt $Length) {
        return $false
    }

    $codes = @()
    foreach ($ch in $chars) {
        $codes += [int][char]$ch
    }

    $lastStart = $Length - $codes.Count
    for ($i = 0; $i -le $lastStart; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $codes.Count; $j++) {
            $addr = $Start + $i + $j
            $actual = 0
            if ($Map.ContainsKey($addr)) {
                $actual = ([int]$Map[$addr] -band 0xFFFF)
            }
            if ($actual -ne $codes[$j]) {
                $ok = $false
                break
            }
        }
        if ($ok) {
            return $true
        }
    }
    return $false
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
$defaultCorpusRoot = Join-Path $defaultRepoRoot "projects/12"

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
    throw "Project 12 corpus root not found: $corpusAbs`nUse -Fetch or pass -CorpusRoot."
}

$python = Get-Command python -ErrorAction Stop
$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null
if ($VmSyncWaits -lt -1) {
    throw "VmSyncWaits must be -1 (disabled) or >= 0, got $VmSyncWaits"
}

$runtimeClassesAll = @("Sys", "Memory", "Array", "String", "Math", "Output", "Keyboard", "Screen")
$runtimeClassesHybridFull = @("Sys", "Memory", "Array", "String", "Math")
$runtimeVmMap = @{}
$runtimeSourceDesc = $stubsDir

if ($RuntimeMode -eq "os_jack") {
    $defaultOsRoot = $defaultOsJackRuntimeDir
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
        Name = "ArrayTest"
        DirName = "ArrayTest"
        SupportsRuntimeModes = @("stubs", "hybrid", "full", "os_jack")
        RuntimeClasses = @("Sys", "Memory", "Array")
        Cycles = 180000
        RamBase = 7998
        RamWords = 64
        ScreenWords = 1
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "Math.vm", "Output.vm", "Keyboard.vm")
        Checks = @(
            @{ Addr = 8000; Value = 222 },
            @{ Addr = 8001; Value = 122 },
            @{ Addr = 8002; Value = 100 },
            @{ Addr = 8003; Value = 10 }
        )
    },
    @{
        Name = "MemoryTest"
        DirName = "MemoryTest"
        SupportsRuntimeModes = @("stubs", "hybrid", "full", "os_jack")
        RuntimeClasses = @("Sys", "Memory", "Array")
        Cycles = 260000
        RamBase = 7998
        RamWords = 64
        ScreenWords = 1
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "Math.vm", "Output.vm", "Keyboard.vm")
        Checks = @(
            @{ Addr = 8000; Value = 333 },
            @{ Addr = 8001; Value = 334 },
            @{ Addr = 8002; Value = 222 },
            @{ Addr = 8003; Value = 122 },
            @{ Addr = 8004; Value = 100 },
            @{ Addr = 8005; Value = 10 }
        )
    },
    @{
        Name = "MathTest"
        DirName = "MathTest"
        SupportsRuntimeModes = @("stubs", "hybrid", "full", "os_jack")
        RuntimeClasses = @("Sys", "Memory", "Math")
        Cycles = 1600000
        RamBase = 7998
        RamWords = 96
        ScreenWords = 1
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "Math.vm", "Output.vm", "Keyboard.vm")
        Checks = @(
            @{ Addr = 8000; Value = 6 },
            @{ Addr = 8001; Value = 0xFF4C },
            @{ Addr = 8002; Value = 0xB9B0 },
            @{ Addr = 8003; Value = 0xB9B0 },
            @{ Addr = 8004; Value = 0 },
            @{ Addr = 8005; Value = 3 },
            @{ Addr = 8006; Value = 0xF448 },
            @{ Addr = 8007; Value = 0 },
            @{ Addr = 8008; Value = 3 },
            @{ Addr = 8009; Value = 181 },
            @{ Addr = 8010; Value = 123 },
            @{ Addr = 8011; Value = 123 },
            @{ Addr = 8012; Value = 27 },
            @{ Addr = 8013; Value = 32767 }
        )
    }
)

if ($IncludeStringTest) {
    $allCases += @{
        Name = "StringTest"
        DirName = "StringTest"
        SupportsRuntimeModes = @("stubs", "hybrid", "os_jack")
        RuntimeClasses = @("Sys", "Memory", "Math", "String", "Output")
        Cycles = 2000000
        RamBase = 3490
        RamWords = 1024
        ScreenWords = 1
        JackArgs = @("--compact-string-literals")
        VmArgs = @("--sync-waits", "1")
        StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm")
        Checks = @(
            @{ Addr = 3500; Value = 5 },
            @{ Addr = 3501; Value = 99 },
            @{ Addr = 3502; Value = 456 },
            @{ Addr = 3503; Value = 0x8285 },
            @{ Addr = 3504; Value = 129 },
            @{ Addr = 3505; Value = 34 },
            @{ Addr = 3506; Value = 128 },
            @{ Addr = 3700; Value = 110 } # 'n' from "new,appendChar: "
        )
    }
}

if ($IncludeExtendedTests) {
    $allCases += @(
        @{
            Name = "OutputTest"
            DirName = "OutputTest"
            SupportsRuntimeModes = @("stubs", "hybrid", "os_jack")
            RuntimeClasses = @("Sys", "Memory", "Math", "String", "Output")
            Cycles = 450000
            RamBase = 3490
            RamWords = 1024
            ScreenWords = 1
            StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm")
            Checks = @(
                @{ Addr = 3598; Value = 2 },      # moveCursor row
                @{ Addr = 3599; Value = 0 },      # moveCursor col
                @{ Addr = 3500; Value = 0xCFC7 }, # printInt(-12345)
                @{ Addr = 3501; Value = 6789 },   # printInt(6789)
                @{ Addr = 3700; Value = 66 },     # 'B'
                @{ Addr = 3701; Value = 67 },     # 'C'
                @{ Addr = 3702; Value = 68 },     # 'D'
                @{ Addr = 3703; Value = 65 },     # 'A'
                @{ Addr = 3704; Value = 48 }      # '0'
            )
            AsciiContains = @(
                @{ Start = 3700; Length = 768; Text = "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz" },
                @{ Start = 3700; Length = 768; Text = "0123456789" }
            )
        },
        @{
            Name = "ScreenTest"
            DirName = "ScreenTest"
            SupportsRuntimeModes = @("stubs", "hybrid", "os_jack")
            RuntimeClasses = @("Sys", "Memory", "Math", "Screen")
            Cycles = 220000
            RamBase = 3584
            RamWords = 128
            ScreenWords = 64
            StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm", "Screen.vm")
            Checks = @(
                @{ Addr = 3600; Value = 3 } # drawRectangle counter
            )
            ScreenChecks = @(
                @{ Addr = 0; Value = 3 } # synthetic marker written by Screen.drawRectangle stub
            )
        },
        @{
            Name = "SysTest"
            DirName = "SysTest"
            SupportsRuntimeModes = @("stubs", "hybrid", "os_jack")
            RuntimeClasses = @("Sys", "Memory", "Math", "String", "Output", "Keyboard")
            Cycles = 700000
            RamBase = 3490
            RamWords = 1536
            ScreenWords = 1
            RamInit = @(
                "0c1c 0081", # keyPressed script: non-zero press
                "0c1d 0081",
                "0c1e 0000"  # release
            )
            StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "MathLite.vm", "Output.vm", "KeyboardLite.vm")
            Checks = @(
                @{ Addr = 3700; Value = 87 } # 'W' from "Wait test:"
            )
            AsciiContains = @(
                @{ Start = 3700; Length = 1024; Text = "Wait test:" },
                @{ Start = 3700; Length = 1024; Text = "Time is up. Make sure that 2 seconds elapsed." }
            )
        },
        @{
            Name = "KeyboardTest"
            DirName = "KeyboardTest"
            SupportsRuntimeModes = @("stubs", "hybrid", "os_jack")
            RuntimeClasses = @("Sys", "Memory", "Math", "String", "Output", "Keyboard")
            Cycles = 2200000
            RamBase = 3490
            RamWords = 2048
            ScreenWords = 1
            JackArgs = @("--compact-string-literals")
            VmArgs = @("--sync-waits", "1")
            RamInit = @(
                "0c1c 0000", # keyPressed script: idle
                "0c1d 0089", # keyPressed script: PageDown(137)
                "0c1e 0089", # hold
                "0c1f 0000", # release
                "0ce4 0001", # readChar script count
                "0ce5 0033", # '3'
                "0bb8 7fff", # readInt sentinel -> readLine + intValue
                "0c80 0004", # readLine #1 len("JACK")
                "0c81 004a", # 'J'
                "0c82 0041", # 'A'
                "0c83 0043", # 'C'
                "0c84 004b", # 'K'
                "0c85 0006", # readLine #2 len("-32123")
                "0c86 002d", # '-'
                "0c87 0033", # '3'
                "0c88 0032", # '2'
                "0c89 0031", # '1'
                "0c8a 0032", # '2'
                "0c8b 0033"  # '3'
            )
            StubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "MathLite.vm", "Output.vm", "Keyboard.vm")
            Checks = @(
                @{ Addr = 3700; Value = 107 } # 'k' from "keyPressed test:"
            )
            AsciiContains = @(
                @{ Start = 3700; Length = 1400; Text = "keyPressed test:" },
                @{ Start = 3700; Length = 1400; Text = "readChar test:" },
                @{ Start = 3700; Length = 1400; Text = "readLine test:" },
                @{ Start = 3700; Length = 1400; Text = "readInt test:" },
                @{ Start = 3700; Length = 1400; Text = "Test completed successfully" }
            )
        }
    )
}

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

if (($RuntimeMode -eq "full") -or ($RuntimeMode -eq "os_jack")) {
    $unsupported = @()
    foreach ($c in $selected) {
        if ($c.ContainsKey("SupportsRuntimeModes") -and ($c.SupportsRuntimeModes -notcontains $RuntimeMode)) {
            $unsupported += $c.Name
        }
    }
    if ($unsupported.Count -gt 0) {
        throw ("RuntimeMode={0} is not supported for cases: {1}. Use -RuntimeMode stubs|hybrid for these cases." -f $RuntimeMode, (($unsupported | Sort-Object -Unique) -join ", "))
    }
}

Write-Host "[INFO] Running project 12 API smoke (sim_full)."
Write-Host "[INFO] Corpus root: $corpusAbs"
Write-Host "[INFO] Runtime mode: $RuntimeMode"
Write-Host "[INFO] Check mode: $CheckMode"
Write-Host "[INFO] Runtime source: $runtimeSourceDesc"
Write-Host "[INFO] Cases: $((($selected | ForEach-Object { $_.Name }) -join ', '))"
Write-Host "[INFO] CompactStringLiterals: $CompactStringLiterals"
Write-Host "[INFO] VmSyncWaits override: $VmSyncWaits"
if ($ReportFpgaFitBudget) {
    Write-Host "[INFO] fpga_fit budget report enabled (ROM_ADDR_W=14, SCREEN_ADDR_W=9)."
    if ($FailOnFpgaFitBudget) {
        Write-Host "[INFO] fpga_fit budget overflow is fatal for this run."
    }
}
if ($IncludeExtendedTests) {
    Write-Host "[INFO] Extended tests enabled (OutputTest, ScreenTest, SysTest, KeyboardTest)."
    Write-Host "[INFO] KeyboardTest uses compact Jack string literals + VM sync-waits=1 for sim_full ROM fit."
}

$failures = @()
$results = @()

foreach ($c in $selected) {
    $caseDir = Join-Path $corpusAbs $c.DirName
    $caseOut = Join-Path $outAbs $c.Name
    $vmOut = Join-Path $caseOut "vm"
    $asmOut = Join-Path $caseOut "program.asm"
    $hackOut = Join-Path $caseOut "program.hack"
    $runnerOut = Join-Path $caseOut "runner"
    $ramInitPath = ""
    $fpgaFitBudgetStatus = "n/a"
    $fpgaFitBudgetReason = "not_requested"
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
    if ($CompactStringLiterals) {
        $jackArgs += @("--compact-string-literals")
    }
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

    $stubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "Math.vm", "Output.vm", "Keyboard.vm")
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
        $runtimeClassesForCase = @($runtimeClassesAll)
        if ($c.ContainsKey("RuntimeClasses") -and $c.RuntimeClasses.Count -gt 0) {
            $runtimeClassesForCase = @($c.RuntimeClasses | Select-Object -Unique)
        }
        foreach ($cls in $runtimeClassesForCase) {
            if (-not $runtimeVmMap.ContainsKey($cls)) {
                throw "Runtime class '$cls' is missing in runtime map for case $($c.Name)"
            }
            Copy-Item -LiteralPath $runtimeVmMap[$cls] -Destination (Join-Path $vmOut "$cls.vm") -Force
        }
    }

    $vmArgs = @($vmTool, $vmOut, "-o", $asmOut, "--bootstrap")
    if ($VmSyncWaits -ge 0) {
        $vmArgs += @("--sync-waits", "$VmSyncWaits")
    }
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

    $screenWords = 1
    if ($c.ContainsKey("ScreenWords")) {
        $screenWords = [int]$c.ScreenWords
    }

    powershell -ExecutionPolicy Bypass -File $budgetTool `
        -HackFile $hackOut `
        -Profile sim_full `
        -RomAddrW 15 `
        -ScreenAddrW 13 `
        -RamBase $c.RamBase `
        -RamWords $c.RamWords `
        -ScreenWords $screenWords
    if ($LASTEXITCODE -ne 0) {
        $failures += $c.Name
        $results += [PSCustomObject]@{
            Name = $c.Name
            Status = "FAIL"
            Reason = "Budget check failed"
            OutDir = $caseOut
            FpgaFitBudget = $fpgaFitBudgetStatus
            FpgaFitBudgetReason = $fpgaFitBudgetReason
        }
        if (-not $ContinueOnFailure) { break }
        continue
    }

    if ($ReportFpgaFitBudget) {
        $savedEap = $ErrorActionPreference
        $fpgaBudgetExit = 1
        try {
            $ErrorActionPreference = "Continue"
            & powershell -ExecutionPolicy Bypass -File $budgetTool `
                -HackFile $hackOut `
                -Profile fpga_fit `
                -RomAddrW 14 `
                -ScreenAddrW 9 `
                -RamBase $c.RamBase `
                -RamWords $c.RamWords `
                -ScreenWords $screenWords *> $null
            $fpgaBudgetExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedEap
        }

        if ($fpgaBudgetExit -eq 0) {
            $fpgaFitBudgetStatus = "PASS"
            $fpgaFitBudgetReason = "ok"
        } else {
            $fpgaFitBudgetStatus = "FAIL"
            $fpgaFitBudgetReason = "overflow_or_window"
            Write-Host ("[WARN] fpga_fit budget check failed for case {0}" -f $c.Name)
            if ($FailOnFpgaFitBudget) {
                $failures += $c.Name
                $results += [PSCustomObject]@{
                    Name = $c.Name
                    Status = "FAIL"
                    Reason = "fpga_fit budget check failed"
                    OutDir = $caseOut
                    FpgaFitBudget = $fpgaFitBudgetStatus
                    FpgaFitBudgetReason = $fpgaFitBudgetReason
                }
                if (-not $ContinueOnFailure) { break }
                continue
            }
        }
    }

    try {
        if ($c.ContainsKey("RamInit") -and $c.RamInit.Count -gt 0) {
            $ramInitPath = New-RamInitFile -Lines $c.RamInit
        }

        $runnerArgs = @(
            "-ExecutionPolicy", "Bypass",
            "-File", $runnerTool,
            "-HackFile", $hackOut,
            "-Profile", "sim_full",
            "-Cycles", $c.Cycles,
            "-RamBase", $c.RamBase,
            "-RamWords", $c.RamWords,
            "-ScreenWords", $screenWords,
            "-OutDir", $runnerOut
        )
        if ($ramInitPath -ne "") {
            $runnerArgs += @("-RamInitFile", $ramInitPath)
        }

        & powershell @runnerArgs
        if ($LASTEXITCODE -ne 0) {
            throw "run_hack_runner failed"
        }

        $ramDump = Join-Path $runnerOut "ram_dump.txt"
        if (-not (Test-Path -LiteralPath $ramDump)) {
            throw "Missing RAM dump: $ramDump"
        }
        if ($CheckMode -eq "strict") {
            $ramMap = Get-DumpMap -DumpPath $ramDump

            foreach ($check in $c.Checks) {
                Assert-Check -Kind "RAM" -Map $ramMap -Check $check
            }

            if ($c.ContainsKey("ScreenChecks") -and $c.ScreenChecks.Count -gt 0) {
                $screenDump = Join-Path $runnerOut "screen_dump.txt"
                if (-not (Test-Path -LiteralPath $screenDump)) {
                    throw "Missing SCREEN dump: $screenDump"
                }
                $screenMap = Get-DumpMap -DumpPath $screenDump
                foreach ($check in $c.ScreenChecks) {
                    Assert-Check -Kind "SCREEN" -Map $screenMap -Check $check
                }
            }

            if ($c.ContainsKey("AsciiContains") -and $c.AsciiContains.Count -gt 0) {
                foreach ($spec in $c.AsciiContains) {
                    $found = Test-AsciiContains `
                        -Map $ramMap `
                        -Start ([int]$spec.Start) `
                        -Length ([int]$spec.Length) `
                        -Text ([string]$spec.Text)
                    if (-not $found) {
                        throw ("ASCII sequence not found in RAM window start=0x{0:x4} len={1}: '{2}'" -f ([int]$spec.Start), ([int]$spec.Length), ([string]$spec.Text))
                    }
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
            Remove-Item -LiteralPath $ramInitPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($CheckMode -eq "strict") {
        Write-Host "[PASS] $($c.Name) API check passed."
    } else {
        Write-Host "[PASS] $($c.Name) compile/run smoke passed (checks skipped)."
    }
    $results += [PSCustomObject]@{
        Name = $c.Name
        Status = "PASS"
        Reason = $(if ($CheckMode -eq "strict") { "ok" } else { "compile_only" })
        OutDir = $caseOut
        FpgaFitBudget = $fpgaFitBudgetStatus
        FpgaFitBudgetReason = $fpgaFitBudgetReason
    }
}

$summary = Join-Path $outAbs "summary.txt"
$summaryLines = @(
    "Project 12 API smoke summary (sim_full)",
    "Corpus root: $corpusAbs",
    "Runtime mode: $RuntimeMode",
    "Check mode: $CheckMode",
    "CompactStringLiterals: $CompactStringLiterals",
    "VmSyncWaits: $VmSyncWaits",
    "fpga_fit budget report: $ReportFpgaFitBudget",
    "fpga_fit budget fail mode: $FailOnFpgaFitBudget",
    "Runtime source: $runtimeSourceDesc",
    "Cases requested: $($selected.Count)",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    ""
)
foreach ($r in $results) {
    $fpgaBudget = if ($r.PSObject.Properties["FpgaFitBudget"]) { $r.FpgaFitBudget } else { "n/a" }
    $fpgaBudgetReason = if ($r.PSObject.Properties["FpgaFitBudgetReason"]) { $r.FpgaFitBudgetReason } else { "n/a" }
    $summaryLines += ("{0,-14} {1,-4} reason={2} fpga_fit_budget={3} ({4}) out={5}" -f $r.Name, $r.Status, $r.Reason, $fpgaBudget, $fpgaBudgetReason, $r.OutDir)
}
Set-Content -LiteralPath $summary -Value $summaryLines -Encoding ASCII

if ($ReportFpgaFitBudget) {
    $budgetSummary = Join-Path $outAbs "fpga_fit_budget_summary.txt"
    $budgetLines = @(
        "Project 12 API smoke fpga_fit budget summary",
        "Runtime mode: $RuntimeMode",
        "Check mode: $CheckMode",
        "FailOnFpgaFitBudget: $FailOnFpgaFitBudget",
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        ""
    )
    foreach ($r in $results) {
        $fpgaBudget = if ($r.PSObject.Properties["FpgaFitBudget"]) { $r.FpgaFitBudget } else { "n/a" }
        $fpgaBudgetReason = if ($r.PSObject.Properties["FpgaFitBudgetReason"]) { $r.FpgaFitBudgetReason } else { "n/a" }
        $budgetLines += ("{0,-14} case_status={1,-4} fpga_fit_budget={2} reason={3}" -f $r.Name, $r.Status, $fpgaBudget, $fpgaBudgetReason)
    }
    Set-Content -LiteralPath $budgetSummary -Value $budgetLines -Encoding ASCII
    Write-Host "[INFO] fpga_fit budget summary: $budgetSummary"
}

if ($failures.Count -gt 0) {
    Write-Host "[INFO] Summary: $summary"
    throw ("Project 12 API smoke failed. Failed cases: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Project 12 API smoke passed."
Write-Host "  Cases  : $($selected.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
