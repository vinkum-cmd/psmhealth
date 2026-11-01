# Builds dist\psm-test-win-<version>.zip (code, docs, example environment - no site data, logs or results) plus a SHA256 file. Runs the offline self-test first.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot; $v = (Get-Content -Raw (Join-Path $root 'VERSION')).Trim(); $dist = Join-Path $root 'dist'; New-Item -ItemType Directory -Force -Path $dist | Out-Null
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # capturing the child's error text must not stop this script
$st = @(& powershell.exe -STA -NoProfile -File (Join-Path $root 'tests\Test-Selftest.ps1') 2>&1 | ForEach-Object { "$_" }); $selfExit = $LASTEXITCODE
$ErrorActionPreference = $eap
if ($selfExit -ne 0) {   # show WHY: the failing checks and the summary (or the last lines if the test itself crashed)
  $why = @($st | Where-Object { $_ -match 'FAIL|checks passed|rror|xception|char:' }); if (-not $why) { $why = @($st | Select-Object -Last 15) }
  $why | ForEach-Object { Write-Host $_ }
  throw 'self-test failed - not releasing (the lines above say which check failed; run .\tests\Test-Selftest.ps1 to see everything)'
}
$stage = Join-Path ([IO.Path]::GetTempPath()) "psm-rel-$v"; if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }; New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($i in 'README.md', 'VERSION', 'Run-PsmTests.ps1', 'Sign-Scripts.ps1', 'Make-Release.ps1', 'lib', 'docs', 'tests') { Copy-Item -Recurse (Join-Path $root $i) $stage }
New-Item -ItemType Directory -Path (Join-Path $stage 'envs') | Out-Null; Copy-Item -Recurse (Join-Path $root 'envs\example') (Join-Path $stage 'envs')
$zip = Join-Path $dist "psm-test-win-$v.zip"; if (Test-Path $zip) { Remove-Item $zip }; Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
(Get-FileHash -Algorithm SHA256 $zip).Hash + "  psm-test-win-$v.zip" | Set-Content (Join-Path $dist "psm-test-win-$v.SHA256SUMS"); Get-Content (Join-Path $dist "psm-test-win-$v.SHA256SUMS")
Remove-Item -Recurse -Force $stage
