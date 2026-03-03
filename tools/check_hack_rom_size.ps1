param(
    [Parameter(Mandatory = $true)]
    [string]$HackFile,

    [ValidateSet("fpga_fit", "sim_full")]
    [string]$Profile = "fpga_fit",

    [int]$RomAddrW = -1
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $HackFile)) {
    Write-Error "File not found: $HackFile"
    exit 2
}

if ($RomAddrW -lt 0) {
    switch ($Profile) {
        "fpga_fit" { $RomAddrW = 14 }
        "sim_full" { $RomAddrW = 15 }
        default { throw "Unsupported profile: $Profile" }
    }
}

if ($RomAddrW -lt 1 -or $RomAddrW -gt 15) {
    Write-Error "RomAddrW must be in [1..15], got $RomAddrW"
    exit 2
}

$romWords = [int][math]::Pow(2, $RomAddrW)
$lineRegex = '^[01]{16}$'
$validWords = 0
$invalid = @()
$lineNo = 0

Get-Content -LiteralPath $HackFile | ForEach-Object {
    $lineNo++
    $s = $_.Trim()
    if ($s -eq "") { return }
    if ($s.StartsWith("//")) { return }

    if ($s -match $lineRegex) {
        $validWords++
    } else {
        $invalid += "line ${lineNo}: '$s'"
    }
}

if ($invalid.Count -gt 0) {
    Write-Host "[ERROR] Invalid .hack format in $HackFile"
    $invalid | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }
    if ($invalid.Count -gt 8) {
        Write-Host "  ... and $($invalid.Count - 8) more invalid lines"
    }
    exit 2
}

Write-Host "[INFO] Profile: $Profile (ROM_ADDR_W=$RomAddrW, ROM_WORDS=$romWords)"
Write-Host "[INFO] Program words: $validWords"

if ($validWords -gt $romWords) {
    Write-Host "[ERROR] Program does not fit ROM: $validWords > $romWords"
    exit 1
}

$free = $romWords - $validWords
Write-Host "[OK] Program fits ROM. Free words: $free"
exit 0
