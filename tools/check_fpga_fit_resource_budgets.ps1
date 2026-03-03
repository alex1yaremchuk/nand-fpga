param(
    [string]$OutDir = "build/fpga_fit_budget"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

$asmTool = Join-Path $repoRoot "tools/hack_asm.py"
$vmTool = Join-Path $repoRoot "tools/hack_vm.py"
$budgetTool = Join-Path $repoRoot "tools/check_profile_resource_budget.ps1"
$programDir = Join-Path $repoRoot "tools/programs"

foreach ($f in @($asmTool, $vmTool, $budgetTool, $programDir)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing required path: $f"
    }
}

$python = Get-Command python -ErrorAction Stop
$outAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $outAbs | Out-Null

function Assemble-Asm([string]$name) {
    $asm = Join-Path $programDir "$name.asm"
    $hack = Join-Path $outAbs "$name.hack"
    & $python.Source $asmTool $asm -o $hack | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Assembly failed for $name"
    }
    return $hack
}

function Check-Budget([string]$hackPath, [int]$ramBase, [int]$ramWords, [int]$screenWords) {
    powershell -ExecutionPolicy Bypass -File $budgetTool `
        -HackFile $hackPath `
        -Profile fpga_fit `
        -RamBase $ramBase `
        -RamWords $ramWords `
        -ScreenWords $screenWords
    if ($LASTEXITCODE -ne 0) {
        throw "Budget check failed for $hackPath"
    }
}

Write-Host "[INFO] Checking Add.asm budget..."
$addHack = Assemble-Asm "Add"
Check-Budget -hackPath $addHack -ramBase 2 -ramWords 1 -screenWords 1

Write-Host "[INFO] Checking Max.asm budget..."
$maxHack = Assemble-Asm "Max"
Check-Budget -hackPath $maxHack -ramBase 2 -ramWords 1 -screenWords 1

Write-Host "[INFO] Checking Rect.asm budget..."
$rectHack = Assemble-Asm "Rect"
Check-Budget -hackPath $rectHack -ramBase 0 -ramWords 1 -screenWords 5

Write-Host "[INFO] Checking VmSmokeSys.vm budget..."
$vmAsm = Join-Path $outAbs "VmSmokeSys.asm"
$vmHack = Join-Path $outAbs "VmSmokeSys.hack"
& $python.Source $vmTool (Join-Path $programDir "VmSmokeSys.vm") -o $vmAsm --bootstrap | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "VM translation failed for VmSmokeSys"
}
@(
    "(VM_SMOKE_END)",
    "@VM_SMOKE_END",
    "0;JMP"
) | Add-Content -Path $vmAsm -Encoding ASCII
& $python.Source $asmTool $vmAsm -o $vmHack | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Assembly failed for VmSmokeSys"
}
Check-Budget -hackPath $vmHack -ramBase 0 -ramWords 32 -screenWords 1

Write-Host "[PASS] fpga_fit resource budget checks passed."
