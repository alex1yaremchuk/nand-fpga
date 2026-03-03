param(
    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",

    [string]$HackFile = "",
    [int]$RomAddrW = -1,
    [int]$ScreenAddrW = -1,

    [int]$RamBase = 0,
    [int]$RamWords = 0,
    [int]$ScreenWords = 0
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

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

if ($RomAddrW -lt 1 -or $RomAddrW -gt 15) {
    throw "RomAddrW must be in [1..15], got $RomAddrW"
}
if ($ScreenAddrW -lt 1 -or $ScreenAddrW -gt 13) {
    throw "ScreenAddrW must be in [1..13], got $ScreenAddrW"
}
if ($RamBase -lt 0 -or $RamWords -lt 0 -or $ScreenWords -lt 0) {
    throw "RamBase/RamWords/ScreenWords must be >= 0"
}

$ramCap = 16384
$screenCap = [int][math]::Pow(2, $ScreenAddrW)
$romCap = [int][math]::Pow(2, $RomAddrW)

if (($RamBase + $RamWords) -gt $ramCap) {
    throw ("RAM window exceeds profile capacity: base={0} words={1} cap={2}" -f $RamBase, $RamWords, $ramCap)
}
if ($ScreenWords -gt $screenCap) {
    throw ("SCREEN window exceeds profile capacity: words={0} cap={1}" -f $ScreenWords, $screenCap)
}

Write-Host "[INFO] Profile budget caps: ROM=$romCap RAM=$ramCap SCREEN=$screenCap"
Write-Host ("[INFO] Requested windows: RAM base={0} words={1}, SCREEN words={2}" -f $RamBase, $RamWords, $ScreenWords)

if ($HackFile -ne "") {
    $hackPath = if ([System.IO.Path]::IsPathRooted($HackFile)) { $HackFile } else { Join-Path $repoRoot $HackFile }
    if (-not (Test-Path -LiteralPath $hackPath)) {
        throw "Hack file not found: $hackPath"
    }

    $romCheck = Join-Path $repoRoot "tools/check_hack_rom_size.ps1"
    if (-not (Test-Path -LiteralPath $romCheck)) {
        throw "Missing ROM check script: $romCheck"
    }

    powershell -ExecutionPolicy Bypass -File $romCheck -HackFile $hackPath -Profile $Profile -RomAddrW $RomAddrW
    if ($LASTEXITCODE -ne 0) {
        throw "ROM budget check failed for $hackPath"
    }
}

Write-Host "[OK] Resource budget check passed."
exit 0
