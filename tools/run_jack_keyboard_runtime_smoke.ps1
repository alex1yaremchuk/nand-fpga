param(
    [string]$JackInput = "tools/programs/JackKeyboardIntSmoke",
    [string]$OutDir = "build/jack_keyboard_runtime_smoke",
    [int]$Cycles = 260000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

$jackTool = Join-Path $repoRoot "tools/hack_jack.py"
$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$runnerTool = Join-Path $repoRoot "tools/run_hack_runner.ps1"
$budgetTool = Join-Path $repoRoot "tools/check_profile_resource_budget.ps1"
$stubsDir = Join-Path $repoRoot "tools/programs/JackOfficialRuntimeStubs"

foreach ($required in @($jackTool, $vmTool, $asmTool, $runnerTool, $budgetTool, $stubsDir)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required path: $required"
    }
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

$python = Get-Command python -ErrorAction Stop
$jackPath = if ([System.IO.Path]::IsPathRooted($JackInput)) { $JackInput } else { Join-Path $repoRoot $JackInput }
if (-not (Test-Path -LiteralPath $jackPath -PathType Container)) {
    throw "Jack input directory not found: $jackPath"
}

$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
$vmOut = Join-Path $outAbs "vm"
$asmOut = Join-Path $outAbs "program.asm"
$hackOut = Join-Path $outAbs "program.hack"
$runnerOut = Join-Path $outAbs "runner"
$ramInit = Join-Path $outAbs "ram_init.txt"

New-Item -ItemType Directory -Force -Path $vmOut | Out-Null
Get-ChildItem -Path $vmOut -Filter *.vm -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "[INFO] Compiling Jack -> VM..."
& $python.Source $jackTool $jackPath -o $vmOut
if ($LASTEXITCODE -ne 0) {
    throw "Jack compilation failed"
}

$stubFiles = @("Sys.vm", "Memory.vm", "Array.vm", "String.vm", "Math.vm", "Output.vm", "Keyboard.vm")
foreach ($stub in $stubFiles) {
    $stubPath = Join-Path $stubsDir $stub
    if (-not (Test-Path -LiteralPath $stubPath -PathType Leaf)) {
        throw "Missing stub VM file: $stubPath"
    }
    Copy-Item -Path $stubPath -Destination $vmOut -Force
}

@(
    "0bb8 007b", # RAM[3000] = 123
    "0bb9 7fff", # RAM[3001] = sentinel -> readInt uses readLine+intValue
    "0c80 0002", # RAM[3200] = len("42")
    "0c81 0034", # '4'
    "0c82 0032", # '2'
    "0c83 0003", # RAM[3203] = len("-17")
    "0c84 002d", # '-'
    "0c85 0031", # '1'
    "0c86 0037"  # '7'
) | Set-Content -Path $ramInit -Encoding ASCII

Write-Host "[INFO] Translating VM -> ASM..."
& $python.Source $vmTool $vmOut -o $asmOut --bootstrap
if ($LASTEXITCODE -ne 0) {
    throw "VM translation failed"
}

Write-Host "[INFO] Assembling ASM -> HACK..."
& $python.Source $asmTool $asmOut -o $hackOut
if ($LASTEXITCODE -ne 0) {
    throw "ASM translation failed"
}

$ramBase = 2990
$ramWords = 1024

Write-Host "[INFO] Verifying resource budgets..."
powershell -ExecutionPolicy Bypass -File $budgetTool `
    -HackFile $hackOut `
    -Profile sim_full `
    -RomAddrW 15 `
    -ScreenAddrW 13 `
    -RamBase $ramBase `
    -RamWords $ramWords `
    -ScreenWords 1
if ($LASTEXITCODE -ne 0) {
    throw "Budget check failed"
}

Write-Host "[INFO] Running hack runner..."
powershell -ExecutionPolicy Bypass -File $runnerTool `
    -HackFile $hackOut `
    -Profile sim_full `
    -Cycles $Cycles `
    -RamBase $ramBase `
    -RamWords $ramWords `
    -ScreenWords 1 `
    -RamInitFile $ramInit `
    -OutDir $runnerOut
if ($LASTEXITCODE -ne 0) {
    throw "run_hack_runner failed"
}

$ramDump = Join-Path $runnerOut "ram_dump.txt"
if (-not (Test-Path -LiteralPath $ramDump)) {
    throw "Missing RAM dump: $ramDump"
}

$checks = @(
    @{ Addr = 3820; Value = 123 },
    @{ Addr = 3821; Value = 42 },
    @{ Addr = 3822; Value = 0xFFEF }, # -17
    @{ Addr = 3823; Value = 3 },
    @{ Addr = 3824; Value = 45 },     # '-'
    @{ Addr = 3825; Value = 49 },     # '1'
    @{ Addr = 3826; Value = 55 },     # '7'
    @{ Addr = 3830; Value = 1 }
)

foreach ($check in $checks) {
    $actual = Get-DumpValue -DumpPath $ramDump -Address $check.Addr
    $expect = ($check.Value -band 0xFFFF)
    if ($actual -ne $expect) {
        throw ("RAM mismatch at 0x{0:x4}: got 0x{1:x4}, expected 0x{2:x4}" -f $check.Addr, $actual, $expect)
    }
}

Write-Host "[PASS] Jack Keyboard runtime smoke passed."
Write-Host "  Jack: $jackPath"
Write-Host "  HACK: $hackOut"
Write-Host "  Dump: $runnerOut"
