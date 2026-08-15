$failed = @()
Get-ChildItem "$PSScriptRoot\test-*.ps1" | Sort-Object Name | ForEach-Object {
    Write-Host "== $($_.Name) ==" -ForegroundColor Cyan
    pwsh -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $_.Name }
}
if ($failed) { Write-Host "FAILED FILES: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host "ALL TEST FILES PASSED" -ForegroundColor Green
