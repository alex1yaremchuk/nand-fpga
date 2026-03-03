param(
    [ValidateSet("sim_full", "fpga_fit")]
    [string]$Profile = "sim_full",
    [string]$OutDir = "build/baseline_tests"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$runner = Join-Path $repoRoot "tools/run_hack_runner.ps1"
$programDir = Join-Path $repoRoot "tools/programs"

if (-not (Test-Path -LiteralPath $asmTool)) {
    Write-Host "[ERROR] Missing assembler: $asmTool"
    exit 2
}
if (-not (Test-Path -LiteralPath $runner)) {
    Write-Host "[ERROR] Missing runner: $runner"
    exit 2
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host "[ERROR] python not found in PATH"
    exit 3
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
$progOut = Join-Path $outAbs "programs"
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
    $path = Join-Path $env:TEMP ("ram-init-" + [guid]::NewGuid().ToString() + ".txt")
    $lines | Set-Content -Path $path -Encoding ASCII
    return $path
}

function Run-Program(
    [string]$testName,
    [string]$hackPath,
    [string]$ramInitPath,
    [int]$cycles,
    [int]$ramBase,
    [int]$ramWords,
    [int]$screenWords
) {
    $testOut = Join-Path $outAbs $testName
    New-Item -ItemType Directory -Force -Path $testOut | Out-Null

    $runnerArgs = @(
        "-ExecutionPolicy", "Bypass",
        "-File", $runner,
        "-HackFile", $hackPath,
        "-Profile", $Profile,
        "-Cycles", "$cycles",
        "-RamBase", "$ramBase",
        "-RamWords", "$ramWords",
        "-ScreenWords", "$screenWords",
        "-OutDir", $testOut
    )
    if ($ramInitPath -ne "") {
        $runnerArgs += @("-RamInitFile", $ramInitPath)
    }
    powershell @runnerArgs

    Write-Host "[INFO] $testName runner exit code: $LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        throw "Runner failed for $testName"
    }

    return @{
        PcDump = Join-Path $testOut "pc_dump.txt"
        RamDump = Join-Path $testOut "ram_dump.txt"
        ScreenDump = Join-Path $testOut "screen_dump.txt"
    }
}

$failures = @()

try {
    $addHack = Assemble "Add"
    $maxHack = Assemble "Max"
    $rectHack = Assemble "Rect"

    # Add: RAM[2] = 7 + 5 = 12
    $addInit = New-RamInitFile @("0000 0007", "0001 0005")
    try {
        $out = Run-Program -testName "add" -hackPath $addHack -ramInitPath $addInit -cycles 40 -ramBase 2 -ramWords 1 -screenWords 1
        $line = (Get-Content -LiteralPath $out.RamDump | Select-Object -First 1)
        if ($line -notmatch "\s000c$") {
            $failures += "Add failed: expected RAM[2]=000c, got '$line'"
        }
    } finally {
        Remove-Item $addInit -ErrorAction SilentlyContinue
    }

    # Max case 1: max(3,9)=9
    $maxInit1 = New-RamInitFile @("0000 0003", "0001 0009")
    try {
        $out = Run-Program -testName "max_case1" -hackPath $maxHack -ramInitPath $maxInit1 -cycles 80 -ramBase 2 -ramWords 1 -screenWords 1
        $line = (Get-Content -LiteralPath $out.RamDump | Select-Object -First 1)
        if ($line -notmatch "\s0009$") {
            $failures += "Max case1 failed: expected RAM[2]=0009, got '$line'"
        }
    } finally {
        Remove-Item $maxInit1 -ErrorAction SilentlyContinue
    }

    # Max case 2: max(10,2)=10
    # NOTE: 81 cycles keeps terminal PC/A state deterministic for strict parity checks.
    $maxInit2 = New-RamInitFile @("0000 000a", "0001 0002")
    try {
        $out = Run-Program -testName "max_case2" -hackPath $maxHack -ramInitPath $maxInit2 -cycles 81 -ramBase 2 -ramWords 1 -screenWords 1
        $line = (Get-Content -LiteralPath $out.RamDump | Select-Object -First 1)
        if ($line -notmatch "\s000a$") {
            $failures += "Max case2 failed: expected RAM[2]=000a, got '$line'"
        }
    } finally {
        Remove-Item $maxInit2 -ErrorAction SilentlyContinue
    }

    # Rect (adapted): SCREEN[0..2]=ffff, SCREEN[3]=0000
    $out = Run-Program -testName "rect" -hackPath $rectHack -ramInitPath "" -cycles 40 -ramBase 0 -ramWords 1 -screenWords 5
        $screen = Get-Content -LiteralPath $out.ScreenDump | Select-Object -First 5
        if ($screen.Count -lt 5) {
            $failures += "Rect failed: screen dump too short"
        } else {
            if ($screen[0] -notmatch "\sffff$") { $failures += "Rect failed: SCREEN[0] not ffff ('$($screen[0])')" }
            if ($screen[1] -notmatch "\sffff$") { $failures += "Rect failed: SCREEN[1] not ffff ('$($screen[1])')" }
            if ($screen[2] -notmatch "\sffff$") { $failures += "Rect failed: SCREEN[2] not ffff ('$($screen[2])')" }
            if ($screen[3] -notmatch "\s0000$") { $failures += "Rect failed: SCREEN[3] not 0000 ('$($screen[3])')" }
        }

    if ($failures.Count -gt 0) {
        Write-Host "[ERROR] Baseline program tests failed:"
        $failures | ForEach-Object { Write-Host "  - $_" }
        exit 1
    }

    Write-Host "[OK] Baseline program tests passed."
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
