param(
    [string]$OutDir = "build/tb"
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

$icarus = Resolve-Icarus
if (-not $icarus) {
    Write-Host "[ERROR] iverilog/vvp not found in PATH. Install Icarus Verilog to run this test."
    exit 3
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$tb = Join-Path $repoRoot "tb/uart_bridge_tb.v"
$rtl = @(
    "hack_computer/src/io/uart_rx.v",
    "hack_computer/src/io/uart_tx.v",
    "hack_computer/src/io/uart_bridge.v"
) | ForEach-Object { Join-Path $repoRoot $_ }

foreach ($f in @($tb) + $rtl) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "[ERROR] Missing source: $f"
        exit 2
    }
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null
$simOut = Join-Path $outAbs "uart_bridge_tb.out"

Write-Host "[INFO] Compiling uart_bridge_tb..."
if ($icarus.LibDir) {
    & $icarus.Iverilog -B $icarus.LibDir -g2012 -o $simOut $tb @rtl
} else {
    & $icarus.Iverilog -g2012 -o $simOut $tb @rtl
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] iverilog compile failed"
    exit $LASTEXITCODE
}

Write-Host "[INFO] Running uart_bridge_tb..."
& $icarus.Vvp $simOut
exit $LASTEXITCODE
