param(
    [Parameter(Mandatory = $true)]
    [string]$HackFile,

    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",

    [int]$Cycles = 20000,
    [int]$RomAddrW = -1,
    [int]$ScreenAddrW = -1,
    [int]$RamBase = 0,
    [int]$RamWords = 256,
    [int]$ScreenWords = -1,
    [string]$RamInitFile = "",
    [string]$OutDir = "build/hack_runner"
)

$ErrorActionPreference = "Stop"

function Resolve-Icarus {
    $scoopBin = Join-Path $env:USERPROFILE "scoop\apps\iverilog\current\bin"
    $scoopIverilog = Join-Path $scoopBin "iverilog.exe"
    $scoopVvp = Join-Path $scoopBin "vvp.exe"
    $scoopIvlLib = Join-Path $env:USERPROFILE "scoop\apps\iverilog\current\lib\ivl"

    if ((Test-Path $scoopIverilog) -and (Test-Path $scoopVvp)) {
        $env:PATH = "$scoopBin;$env:PATH"
        return @{
            Iverilog = $scoopIverilog
            Vvp = $scoopVvp
            LibDir = $scoopIvlLib
        }
    }

    $iverilogCmd = Get-Command iverilog -ErrorAction SilentlyContinue
    $vvpCmd = Get-Command vvp -ErrorAction SilentlyContinue
    if (-not $iverilogCmd -or -not $vvpCmd) {
        return $null
    }

    return @{
        Iverilog = $iverilogCmd.Source
        Vvp = $vvpCmd.Source
        LibDir = $null
    }
}

function Normalize-ArgPath([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    return ($full -replace '\\', '/')
}

function Count-HackWords([string]$path) {
    $count = 0
    Get-Content -LiteralPath $path | ForEach-Object {
        $s = $_.Trim()
        if ($s -eq "") { return }
        if ($s.StartsWith("//")) { return }
        if ($s -match '^[01]{16}$') { $count++ }
    }
    return $count
}

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $HackFile)) {
    Write-Host "[ERROR] Hack file not found: $HackFile"
    exit 2
}

if (($RamInitFile -ne "") -and (-not (Test-Path -LiteralPath $RamInitFile))) {
    Write-Host "[ERROR] RAM init file not found: $RamInitFile"
    exit 2
}

if ($RomAddrW -lt 0) {
    switch ($Profile) {
        "fpga_fit" { $RomAddrW = 14 }
        "sim_full" { $RomAddrW = 15 }
        default { throw "Unsupported profile: $Profile" }
    }
}

if ($ScreenAddrW -lt 0) {
    switch ($Profile) {
        "fpga_fit" { $ScreenAddrW = 9 }
        "sim_full" { $ScreenAddrW = 13 }
        default { throw "Unsupported profile: $Profile" }
    }
}

if ($ScreenWords -lt 0) {
    $ScreenWords = [int][math]::Pow(2, $ScreenAddrW)
}

$checkScript = Join-Path $repoRoot "tools/check_profile_resource_budget.ps1"
if (-not (Test-Path -LiteralPath $checkScript)) {
    Write-Host "[ERROR] Missing resource budget script: $checkScript"
    exit 2
}

Write-Host "[INFO] Verifying resource budgets..."
powershell -ExecutionPolicy Bypass -File $checkScript `
    -HackFile $HackFile `
    -Profile $Profile `
    -RomAddrW $RomAddrW `
    -ScreenAddrW $ScreenAddrW `
    -RamBase $RamBase `
    -RamWords $RamWords `
    -ScreenWords $ScreenWords
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Resource budget check failed."
    exit $LASTEXITCODE
}

$icarus = Resolve-Icarus
if (-not $icarus) {
    Write-Host "[ERROR] iverilog/vvp not found in PATH."
    exit 3
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir
} else {
    Join-Path $repoRoot $OutDir
}
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$simOut = Join-Path $outAbs "hack_runner_tb.out"
$pcDump = Join-Path $outAbs "pc_dump.txt"
$ramDump = Join-Path $outAbs "ram_dump.txt"
$screenDump = Join-Path $outAbs "screen_dump.txt"

$tbFile = Join-Path $repoRoot "tb/hack_runner_tb.v"
$rtlFiles = @(
    "hack_computer/src/core/cpu_core.v",
    "hack_computer/src/mem/rom32k_prog.v",
    "hack_computer/src/mem/memory_map.v",
    "hack_computer/src/mem/ram16k_select.v",
    "hack_computer/src/mem/ram4k_select.v",
    "hack_computer/src/mem/ram512_struct.v",
    "hack_computer/src/mem/ram64_struct.v",
    "hack_computer/src/mem/ram8_struct.v",
    "hack_computer/src/mem/register_n.v",
    "hack_computer/src/mem/ram_bram.v"
) | ForEach-Object { Join-Path $repoRoot $_ }

foreach ($f in @($tbFile) + $rtlFiles) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "[ERROR] Missing source: $f"
        exit 2
    }
}

$defines = @(
    "-DTB_DATA_W=16",
    "-DTB_ADDR_W=15",
    "-DTB_ROM_ADDR_W=$RomAddrW",
    "-DTB_SCREEN_ADDR_W=$ScreenAddrW",
    "-DTB_USE_SCREEN_BRAM=1"
)

$progWords = Count-HackWords -path $HackFile
Write-Host "[INFO] Compiling hack_runner_tb..."
if ($icarus.LibDir) {
    & $icarus.Iverilog -B $icarus.LibDir -g2012 @defines -o $simOut $tbFile @rtlFiles
} else {
    & $icarus.Iverilog -g2012 @defines -o $simOut $tbFile @rtlFiles
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] iverilog compile failed"
    exit $LASTEXITCODE
}

$hackArg = "+hack=$(Normalize-ArgPath $HackFile)"
$pcArg = "+pc_dump=$(Normalize-ArgPath $pcDump)"
$ramArg = "+ram_dump=$(Normalize-ArgPath $ramDump)"
$screenArg = "+screen_dump=$(Normalize-ArgPath $screenDump)"

$simArgs = @(
    $hackArg,
    "+cycles=$Cycles",
    "+prog_words=$progWords",
    "+ram_base=$RamBase",
    "+ram_words=$RamWords",
    "+screen_words=$ScreenWords",
    $pcArg,
    $ramArg,
    $screenArg
)

if ($RamInitFile -ne "") {
    $simArgs += "+ram_init=$(Normalize-ArgPath $RamInitFile)"
}

Write-Host "[INFO] Running hack_runner_tb..."
& $icarus.Vvp $simOut @simArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] vvp run failed"
    exit $LASTEXITCODE
}

Write-Host "[OK] Simulation completed."
Write-Host "  PC dump    : $pcDump"
Write-Host "  RAM dump   : $ramDump"
Write-Host "  SCREEN dump: $screenDump"
exit 0
