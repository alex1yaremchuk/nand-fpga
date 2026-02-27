param(
    [string]$OutDir = "build/tb"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$tbFile = Join-Path $repoRoot "tb/cpu_core_reset_boot_tb.v"
$dutFile = Join-Path $repoRoot "hack_computer/src/core/cpu_core.v"

if (-not (Test-Path -LiteralPath $tbFile)) {
    Write-Host "[ERROR] Testbench not found: $tbFile"
    exit 2
}

if (-not (Test-Path -LiteralPath $dutFile)) {
    Write-Host "[ERROR] DUT not found: $dutFile"
    exit 2
}

function Resolve-Icarus {
    $scoopBin = Join-Path $env:USERPROFILE "scoop\apps\iverilog\current\bin"
    $scoopIverilog = Join-Path $scoopBin "iverilog.exe"
    $scoopVvp = Join-Path $scoopBin "vvp.exe"
    $scoopIvlLib = Join-Path $env:USERPROFILE "scoop\apps\iverilog\current\lib\ivl"

    if ((Test-Path $scoopIverilog) -and (Test-Path $scoopVvp)) {
        # Scoop shim setup often lacks runtime DLL path for ivl.exe.
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

$icarus = Resolve-Icarus
if (-not $icarus) {
    Write-Host "[ERROR] iverilog/vvp not found in PATH. Install Icarus Verilog to run this test."
    exit 3
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir
} else {
    Join-Path $repoRoot $OutDir
}

New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

$simOut = Join-Path $outAbs "cpu_core_reset_boot_tb.out"

Write-Host "[INFO] Compiling cpu_core_reset_boot_tb..."
if ($icarus.LibDir) {
    & $icarus.Iverilog -B $icarus.LibDir -g2012 -o $simOut $tbFile $dutFile
} else {
    & $icarus.Iverilog -g2012 -o $simOut $tbFile $dutFile
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] iverilog compile failed"
    exit $LASTEXITCODE
}

Write-Host "[INFO] Running cpu_core_reset_boot_tb..."
& $icarus.Vvp $simOut
exit $LASTEXITCODE
