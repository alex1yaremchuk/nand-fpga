param(
    [string]$OutDir = "build/hack_asm_tests"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")

Push-Location $repoRoot
try {
    $python = Get-Command python -ErrorAction Stop

    if (-not (Test-Path -LiteralPath "tools/tests/test_hack_asm.py")) {
        throw "Missing tests: tools/tests/test_hack_asm.py"
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $log = Join-Path $OutDir "unittest.log"

    Write-Host "[INFO] Running hack_asm unit tests..."
    $pyCode = @'
import sys
import unittest

suite = unittest.defaultTestLoader.discover("tools/tests", pattern="test_hack_asm.py")
result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
'@
    $pyCode | & $python.Source - *> $log
    $testExit = $LASTEXITCODE
    Get-Content -Path $log
    if ($testExit -ne 0) {
        throw "hack_asm unit tests failed"
    }

    Write-Host "[PASS] hack_asm unit tests passed"
    exit 0
}
finally {
    Pop-Location
}
