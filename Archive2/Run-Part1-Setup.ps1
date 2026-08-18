# Master Script - Part 1: Initial Setup
# Runs Steps 01-03 in succession
# - Prerequisites and Configuration
# - SharePoint Site and List Provisioning
# - Shared Mailbox Creation

$ErrorActionPreference = "Stop"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  MFA ONBOARDING - PART 1: INITIAL SETUP" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

Write-Host "This script will run the following steps:" -ForegroundColor Yellow
Write-Host "  01 - Prerequisites & Configuration" -ForegroundColor Gray
Write-Host "  02 - SharePoint Site & List" -ForegroundColor Gray
Write-Host "  03 - Shared Mailbox`n" -ForegroundColor Gray

$confirmation = Read-Host "Continue? (Y/N)"
if ($confirmation -notmatch '^[Yy]') {
    Write-Host "Cancelled by user." -ForegroundColor Yellow
    exit 0
}

$startTime = Get-Date
$failedSteps = @()

# Step 01 - Prerequisites
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 01 - PREREQUISITES" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\01-Install-Prerequisites.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Step 01 failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Step 01 completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Step 01 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Step 01 - Prerequisites"
    Write-Host "`nCannot continue without completing Step 01." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3

# Step 02 - SharePoint
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 02 - SHAREPOINT PROVISIONING" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\02-Provision-SharePoint.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Step 02 failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Step 02 completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Step 02 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Step 02 - SharePoint"
    Write-Host "`nCannot continue without completing Step 02." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3

# Step 03 - Shared Mailbox
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 03 - SHARED MAILBOX" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\03-Create-Shared-Mailbox.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Step 03 failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Step 03 completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Step 03 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Step 03 - Shared Mailbox"
}

# Summary
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  PART 1 SUMMARY" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

if ($failedSteps.Count -eq 0) {
    Write-Host "✓ ALL STEPS COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "`nDuration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "  1. Review the configuration in mfa-config.ini" -ForegroundColor Gray
    Write-Host "  2. Run Part 2: .\Run-Part2-Deploy.ps1`n" -ForegroundColor Gray
    exit 0
} else {
    Write-Host "✗ SOME STEPS FAILED:" -ForegroundColor Red
    foreach ($step in $failedSteps) {
        Write-Host "  - $step" -ForegroundColor Red
    }
    Write-Host "`nDuration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
    Write-Host "`nPlease fix the errors and re-run the failed steps manually.`n" -ForegroundColor Yellow
    exit 1
}
