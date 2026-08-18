# Master Script - Part 2: Azure Deployment
# Runs Steps 04-07 and fixes in succession
# - Azure Resources
# - Function App Configuration
# - Logic App Deployment
# - Upload Portal Deployment
# - Permission Fixes

$ErrorActionPreference = "Stop"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  MFA ONBOARDING - PART 2: AZURE DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

Write-Host "This script will run the following steps:" -ForegroundColor Yellow
Write-Host "  04 - Azure Resources" -ForegroundColor Gray
Write-Host "  05 - Function App Configuration" -ForegroundColor Gray
Write-Host "  06 - Logic App Deployment" -ForegroundColor Gray
Write-Host "  07 - Upload Portal Deployment" -ForegroundColor Gray
Write-Host "  Set - Function Authentication" -ForegroundColor Gray
Write-Host "  Set - Graph Permissions" -ForegroundColor Gray
Write-Host "  Set - Logic App Permissions`n" -ForegroundColor Gray

$confirmation = Read-Host "Continue? (Y/N)"
if ($confirmation -notmatch '^[Yy]') {
    Write-Host "Cancelled by user." -ForegroundColor Yellow
    exit 0
}

$startTime = Get-Date
$failedSteps = @()

# Step 04 - Azure Resources
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 04 - AZURE RESOURCES" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\04-Create-Azure-Resources.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Step 04 failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Step 04 completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Step 04 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Step 04 - Azure Resources"
    Write-Host "`nCannot continue without completing Step 04." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3

# Step 05 - Function App
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 05 - FUNCTION APP" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\05-Configure-Function-App.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Step 05 failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Step 05 completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Step 05 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Step 05 - Function App"
}

Start-Sleep -Seconds 3

# Step 06 - Logic App
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 06 - LOGIC APP" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\06-Deploy-Logic-App.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Step 06 failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Step 06 completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Step 06 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Step 06 - Logic App"
}

Start-Sleep -Seconds 3

# Step 07 - Upload Portal
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 07 - UPLOAD PORTAL" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\07-Deploy-Upload-Portal1.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Step 07 failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Step 07 completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Step 07 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Step 07 - Upload Portal"
}

Start-Sleep -Seconds 3

# Set - Function Authentication
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING SET - FUNCTION AUTHENTICATION" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\Fix-Function-Auth.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Fix-Function-Auth failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Function Auth set successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Fix-Function-Auth FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Set - Function Authentication"
}

Start-Sleep -Seconds 3

# Set - Graph Permissions
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING SET - GRAPH PERMISSIONS" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\Fix-Graph-Permissions.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Fix-Graph-Permissions failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Graph Permissions set successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Fix-Graph-Permissions FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Set - Graph Permissions"
}

Start-Sleep -Seconds 3

# Set - Logic App Permissions
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING SET - LOGIC APP PERMISSIONS" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

try {
    & "$PSScriptRoot\Check-LogicApp-Permissions.ps1" -AddPermissions
    if ($LASTEXITCODE -ne 0) { throw "Check-LogicApp-Permissions failed with exit code $LASTEXITCODE" }
    Write-Host "`n✓ Logic App Permissions set successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n✗ Check-LogicApp-Permissions FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failedSteps += "Set - Logic App Permissions"
}

# Summary
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  PART 2 SUMMARY" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

if ($failedSteps.Count -eq 0) {
    Write-Host "✓ ALL STEPS COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "`nDuration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
    Write-Host "`n🎉 DEPLOYMENT COMPLETE!" -ForegroundColor Green
    Write-Host "`nYour MFA onboarding solution is now ready to use." -ForegroundColor Cyan
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "  1. Test the upload portal" -ForegroundColor Gray
    Write-Host "  2. Upload a test CSV with user UPNs" -ForegroundColor Gray
    Write-Host "  3. Monitor the SharePoint list for status updates`n" -ForegroundColor Gray
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
