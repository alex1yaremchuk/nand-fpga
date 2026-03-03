param(
    [Parameter(Mandatory = $true)]
    [string]$Port,
    [int]$Baud = 115200,
    [double]$TimeoutSec = 1.0,
    [string]$CorpusRoot = "",
    [switch]$Fetch,
    [string]$OutDir = "build/jack_official_runtime_fpga_subset_hw",
    [string[]]$Case = @(),
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$romAddrW = 14
$runtimeSmoke = Join-Path $repoRoot "tools/run_jack_official_runtime_sim.ps1"
$subsetStubsRoot = Join-Path $repoRoot "tools/programs/JackOfficialRuntimeFpgaSubsetStubs"
$uartClient = Join-Path $repoRoot "tools/hack_uart_client.py"
$python = Get-Command python -ErrorAction Stop

foreach ($required in @($runtimeSmoke, $uartClient, $subsetStubsRoot)) {
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
    $path = Join-Path $env:TEMP ("jack-official-runtime-fpga-subset-ram-init-" + [guid]::NewGuid().ToString() + ".txt")
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
            $addrToken = $parts[0].Trim().ToLowerInvariant()
            if ($addrToken.StartsWith("0x")) {
                $addr = [Convert]::ToInt32($addrToken.Substring(2), 16)
            } elseif ($addrToken -match "[a-f]") {
                $addr = [Convert]::ToInt32($addrToken, 16)
            } else {
                $addr = [Convert]::ToInt32($addrToken, 10)
            }
            $value = [Convert]::ToInt32($parts[1], 16)
            $map[$addr] = $value
        } catch {
            continue
        }
    }
    return $map
}

function Get-MapValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,
        [Parameter(Mandatory = $true)]
        [int]$Address,
        [Parameter(Mandatory = $true)]
        [string]$Kind
    )
    if (-not $Map.ContainsKey($Address)) {
        throw ("Address not found in {0} dump: 0x{1:x4}" -f $Kind, $Address)
    }
    return ([int]$Map[$Address] -band 0xFFFF)
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

$allCases = @(
    @{
        Name = "Seven"
        Cycles = 12000
        RamBase = 3488
        RamWords = 32
        RamInit = @()
        Checks = @(
            @{ Addr = 3500; Value = 7 }
        )
    },
    @{
        Name = "ConvertToBin"
        Cycles = 120000
        RamBase = 7998
        RamWords = 32
        RamInit = @(
            "1f40 000d" # RAM[8000] = 13
        )
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
        Name = "Average"
        Cycles = 90000
        RamBase = 2990
        RamWords = 1024
        RamInit = @(
            "0bb8 0003", # 3000 = length
            "0bb9 000a", # 3001 = 10
            "0bba 0014", # 3002 = 20
            "0bbb 001e"  # 3003 = 30
        )
        Checks = @(
            @{ Addr = 3500; Value = 20 },
            @{ Addr = 3700; Value = 84 }
        )
    },
    @{
        Name = "ComplexArrays"
        Cycles = 700000
        RamBase = 3496
        RamWords = 320
        RamInit = @()
        Checks = @(
            @{ Addr = 3500; Value = 5 },
            @{ Addr = 3501; Value = 40 },
            @{ Addr = 3502; Value = 0 },
            @{ Addr = 3503; Value = 77 },
            @{ Addr = 3504; Value = 110 },
            @{ Addr = 3700; Value = 84 }
        )
    },
    @{
        Name = "Square"
        Cycles = 180000
        RamBase = 3584
        RamWords = 96
        RamInit = @(
            "0c1c 0051", # Keyboard script: 'q'
            "0c1d 0000"  # release
        )
        Checks = @(
            @{ Addr = 3600; Mode = "ge"; Value = 1 }
        )
        ScreenChecks = @(
            @{ Addr = 0; Mode = "ne"; Value = 0 }
        )
    }
)

$defaultCaseNames = @("Seven", "ConvertToBin", "Average", "Square")
$selected = @()
foreach ($c in $allCases) {
    if ($defaultCaseNames -contains $c.Name) {
        $selected += $c
    }
}
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
        if ($wanted.ContainsKey($c.Name.ToLowerInvariant())) {
            $selected += $c
        }
    }
    if ($selected.Count -eq 0) {
        throw ("No matching cases for -Case. Known cases: {0}" -f (($allCases | ForEach-Object { $_.Name }) -join ", "))
    }
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null
$compileOut = Join-Path $outAbs "compile"
New-Item -ItemType Directory -Force -Path $compileOut | Out-Null

$compileArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $runtimeSmoke,
    "-OutDir", $compileOut,
    "-Profile", "fpga_fit",
    "-StubsRoot", $subsetStubsRoot,
    "-RuntimeMode", "stubs",
    "-CheckMode", "strict",
    "-VmSyncWaits", "1",
    "-Case", (($selected | ForEach-Object { $_.Name }) -join ",")
)
if ($Fetch) { $compileArgs += "-Fetch" }
if ($CorpusRoot -ne "") { $compileArgs += @("-CorpusRoot", $CorpusRoot) }

Write-Host "[INFO] Building runtime subset artifacts for FPGA run..."
powershell @compileArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build runtime subset artifacts"
}

Write-Host "[INFO] Running official Jack runtime fpga_fit subset on FPGA..."
Write-Host "[INFO] Port=$Port Baud=$Baud Cases=$((($selected | ForEach-Object { $_.Name }) -join ', '))"

$failures = @()
$results = @()

foreach ($c in $selected) {
    $caseName = $c.Name
    $hackPath = Join-Path $compileOut (Join-Path $caseName "program.hack")
    $caseOut = Join-Path $outAbs (Join-Path "fpga" $caseName)
    New-Item -ItemType Directory -Force -Path $caseOut | Out-Null
    $clearRamWords = [Math]::Min(16384, [Math]::Max(512, ([int]$c.RamBase + [int]$c.RamWords)))

    if (-not (Test-Path -LiteralPath $hackPath -PathType Leaf)) {
        $failures += $caseName
        $results += [PSCustomObject]@{
            Name = $caseName
            Status = "FAIL"
            Reason = "Missing compiled hack file"
            OutDir = $caseOut
        }
        if (-not $ContinueOnFailure) { break }
        continue
    }

    Write-Host ""
    Write-Host "[CASE] $caseName"
    $ramInitPath = New-RamInitFile -Lines $c.RamInit
    $runArgs = @(
        $uartClient,
        "--port", $Port,
        "--baud", "$Baud",
        "--timeout", "$TimeoutSec",
        "runhack",
        "--hack-file", $hackPath,
        "--cycles", "$($c.Cycles)",
        "--rom-addr-w", "$romAddrW",
        "--ram-base", "$($c.RamBase)",
        "--ram-words", "$($c.RamWords)",
        "--screen-words", "1",
        "--clear-ram-base", "0",
        "--clear-ram-words", "$clearRamWords",
        "--clear-screen-words", "1",
        "--rom-verify",
        "--rom-write-retries", "2",
        "--out-dir", $caseOut
    )
    if ($ramInitPath -ne "") {
        $runArgs += @("--ram-init-file", $ramInitPath)
    }

    try {
        & $python.Source @runArgs
        if ($LASTEXITCODE -ne 0) {
            throw "FPGA run failed"
        }

        $ramDump = Join-Path $caseOut "ram_dump.txt"
        $ramMap = Get-DumpMap -DumpPath $ramDump
        foreach ($check in $c.Checks) {
            $actual = Get-MapValue -Map $ramMap -Address ([int]$check.Addr) -Kind "RAM"
            Assert-Check -Kind "RAM" -Address ([int]$check.Addr) -Actual $actual -Check $check
        }

        if ($c.ContainsKey("ScreenChecks") -and $c.ScreenChecks.Count -gt 0) {
            $screenDump = Join-Path $caseOut "screen_dump.txt"
            $screenMap = Get-DumpMap -DumpPath $screenDump
            foreach ($check in $c.ScreenChecks) {
                $actual = Get-MapValue -Map $screenMap -Address ([int]$check.Addr) -Kind "SCREEN"
                Assert-Check -Kind "SCREEN" -Address ([int]$check.Addr) -Actual $actual -Check $check
            }
        }
    } catch {
        $failures += $caseName
        $results += [PSCustomObject]@{
            Name = $caseName
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

    Write-Host "[PASS] $caseName FPGA check passed."
    $results += [PSCustomObject]@{
        Name = $caseName
        Status = "PASS"
        Reason = "ok"
        OutDir = $caseOut
    }
}

$summary = Join-Path $outAbs "summary.txt"
$summaryLines = @(
    "Official Jack runtime fpga_fit subset FPGA summary",
    "Port: $Port",
    "Baud: $Baud",
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
    throw ("Official Jack runtime fpga_fit subset FPGA run failed. Failed cases: {0}" -f (($failures | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "[PASS] Official Jack runtime fpga_fit subset FPGA run passed."
Write-Host "  Cases  : $($selected.Count)"
Write-Host "  Output : $outAbs"
Write-Host "  Summary: $summary"
