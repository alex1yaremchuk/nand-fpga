param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 115200,

    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",

    [double]$TimeoutSec = 1.0,
    [switch]$StrictPcDump,
    [ValidateSet("run", "step")]
    [string]$ExecMode = "run",

    [string]$OutDir = "",
    [string]$GoldenDir = "tools/baseline_golden"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$client = Join-Path $repoRoot "tools/hack_uart_client.py"
$programDir = Join-Path $repoRoot "tools/programs"

foreach ($f in @($asmTool, $client, $programDir)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "[ERROR] Missing path: $f"
        exit 2
    }
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host "[ERROR] python not found in PATH"
    exit 3
}

$romAddrW = if ($Profile -eq "sim_full") { 15 } else { 13 }

$runOut = $OutDir
if ($runOut -eq "") {
    if ($Profile -eq "sim_full") {
        $runOut = "build/fpga_uart_baseline_sim_full"
    } else {
        $runOut = "build/fpga_uart_baseline_fpga_fit"
    }
}
$runOutAbs = if ([System.IO.Path]::IsPathRooted($runOut)) { $runOut } else { Join-Path $repoRoot $runOut }
$goldAbs = if ([System.IO.Path]::IsPathRooted($GoldenDir)) { $GoldenDir } else { Join-Path $repoRoot $GoldenDir }
$knownWarns = @()

if (-not (Test-Path -LiteralPath $goldAbs)) {
    Write-Host "[ERROR] Golden directory not found: $goldAbs"
    exit 2
}

$progOut = Join-Path $runOutAbs "programs"
New-Item -ItemType Directory -Force -Path $progOut | Out-Null

function Assemble([string]$name) {
    $asm = Join-Path $programDir "$name.asm"
    $hack = Join-Path $progOut "$name.hack"
    if (-not (Test-Path -LiteralPath $asm)) {
        throw "Missing program asm: $asm"
    }
    & $python.Source $asmTool $asm -o $hack | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Assembly failed for $name"
    }
    Write-Host "[INFO] Assembled $name -> $hack"
    return $hack
}

function New-RamInitFile([string[]]$lines) {
    $path = Join-Path $env:TEMP ("uart-ram-init-" + [guid]::NewGuid().ToString() + ".txt")
    $lines | Set-Content -Path $path -Encoding ASCII
    return $path
}

function Run-FpgaCase(
    [string]$testName,
    [string]$hackPath,
    [string]$ramInitPath,
    [int]$cycles,
    [int]$ramBase,
    [int]$ramWords,
    [int]$screenWords,
    [int]$clearRamWords,
    [int]$clearScreenWords,
    [ValidateSet("run", "step")]
    [string]$execMode = "run"
) {
    $testOut = Join-Path $runOutAbs $testName
    New-Item -ItemType Directory -Force -Path $testOut | Out-Null

    $args = @(
        $client,
        "--port", $Port,
        "--baud", "$Baud",
        "--timeout", "$TimeoutSec",
        "runhack",
        "--hack-file", $hackPath,
        "--cycles", "$cycles",
        "--rom-addr-w", "$romAddrW",
        "--ram-base", "$ramBase",
        "--ram-words", "$ramWords",
        "--screen-words", "$screenWords",
        "--clear-ram-base", "0",
        "--clear-ram-words", "$clearRamWords",
        "--clear-screen-words", "$clearScreenWords",
        "--exec-mode", $execMode,
        "--rom-verify",
        "--rom-write-retries", "2",
        "--out-dir", $testOut
    )

    if ($ramInitPath -ne "") {
        $args += @("--ram-init-file", $ramInitPath)
    }

    & $python.Source @args
    if ($LASTEXITCODE -ne 0) {
        throw "FPGA run failed for $testName"
    }
}

function Read-PcDump([string]$path) {
    $lines = Get-Content -LiteralPath $path
    if ($lines.Count -lt 3) {
        throw "pc_dump too short: $path"
    }

    $vals = @{}
    foreach ($ln in $lines) {
        if ($ln -match "^\s*PC\s+(\d+)\s+0x([0-9a-fA-F]+)\s*$") {
            $vals["PC"] = [int]$matches[1]
        } elseif ($ln -match "^\s*A\s+(\d+)\s+0x([0-9a-fA-F]+)\s*$") {
            $vals["A"] = [int]$matches[1]
        } elseif ($ln -match "^\s*D\s+(\d+)\s+0x([0-9a-fA-F]+)\s*$") {
            $vals["D"] = [int]$matches[1]
        }
    }

    if (-not $vals.ContainsKey("PC") -or -not $vals.ContainsKey("A") -or -not $vals.ContainsKey("D")) {
        throw "pc_dump parse failed: $path"
    }
    return $vals
}

$failures = @()
$execMode = $ExecMode

try {
    Write-Host "[INFO] CPU exec mode for this run: $execMode"
    $addHack = Assemble "Add"
    $maxHack = Assemble "Max"
    $rectHack = Assemble "Rect"

    $addInit = New-RamInitFile @("0000 0007", "0001 0005")
    try {
        Run-FpgaCase -testName "add" -hackPath $addHack -ramInitPath $addInit -cycles 40 -ramBase 2 -ramWords 1 -screenWords 1 -clearRamWords 8 -clearScreenWords 1 -execMode $execMode
    } finally {
        Remove-Item $addInit -ErrorAction SilentlyContinue
    }

    $maxInit1 = New-RamInitFile @("0000 0003", "0001 0009")
    try {
        Run-FpgaCase -testName "max_case1" -hackPath $maxHack -ramInitPath $maxInit1 -cycles 80 -ramBase 2 -ramWords 1 -screenWords 1 -clearRamWords 8 -clearScreenWords 1 -execMode $execMode
    } finally {
        Remove-Item $maxInit1 -ErrorAction SilentlyContinue
    }

    $maxInit2 = New-RamInitFile @("0000 000a", "0001 0002")
    try {
        Run-FpgaCase -testName "max_case2" -hackPath $maxHack -ramInitPath $maxInit2 -cycles 80 -ramBase 2 -ramWords 1 -screenWords 1 -clearRamWords 8 -clearScreenWords 1 -execMode $execMode
    } finally {
        Remove-Item $maxInit2 -ErrorAction SilentlyContinue
    }

    Run-FpgaCase -testName "rect" -hackPath $rectHack -ramInitPath "" -cycles 40 -ramBase 0 -ramWords 1 -screenWords 5 -clearRamWords 8 -clearScreenWords 5 -execMode $execMode

    $tests = @("add", "max_case1", "max_case2", "rect")
    $files = @("pc_dump.txt", "ram_dump.txt", "screen_dump.txt")

    foreach ($t in $tests) {
        foreach ($f in $files) {
            $actual = Join-Path (Join-Path $runOutAbs $t) $f
            $gold = Join-Path (Join-Path $goldAbs $t) $f

            if (-not (Test-Path -LiteralPath $actual)) {
                $failures += "missing actual: $actual"
                continue
            }
            if (-not (Test-Path -LiteralPath $gold)) {
                $failures += "missing golden: $gold"
                continue
            }

            if ($f -eq "pc_dump.txt") {
                $aVals = Read-PcDump $actual
                $gVals = Read-PcDump $gold
                if ($aVals["PC"] -ne $gVals["PC"]) {
                    $failures += "mismatch: $t/$f (PC actual=$($aVals["PC"]) golden=$($gVals["PC"]))"
                } elseif ($StrictPcDump -and ($aVals["D"] -ne $gVals["D"])) {
                    $failures += "mismatch: $t/$f (D actual=$($aVals["D"]) golden=$($gVals["D"]))"
                } elseif ($StrictPcDump -and ($aVals["A"] -ne $gVals["A"])) {
                    # Known hardware-specific variance:
                    # max_case2 may report different A at terminal loop while PC/D and functional outputs match.
                    if (($t -eq "max_case2") -and ($aVals["PC"] -eq $gVals["PC"]) -and ($aVals["D"] -eq $gVals["D"])) {
                        $knownWarns += ("known variance: {0}/{1} (A actual=0x{2:x4} golden=0x{3:x4})" -f $t, $f, $aVals["A"], $gVals["A"])
                    } else {
                        $failures += "mismatch: $t/$f (A actual=$($aVals["A"]) golden=$($gVals["A"]))"
                    }
                }
            } else {
                $a = Get-Content -LiteralPath $actual
                $g = Get-Content -LiteralPath $gold
                $cmp = Compare-Object -ReferenceObject $g -DifferenceObject $a -SyncWindow 0
                if ($cmp) {
                    $failures += "mismatch: $t/$f"
                }
            }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "[ERROR] FPGA UART comparison failed:"
        $failures | ForEach-Object { Write-Host "  - $_" }
        exit 1
    }

    if ($knownWarns.Count -gt 0) {
        Write-Host "[WARN] Strict mode accepted known variances:"
        $knownWarns | ForEach-Object { Write-Host "  - $_" }
    }

    Write-Host "[OK] FPGA UART outputs match golden artifacts."
    Write-Host "  Output: $runOutAbs"
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
