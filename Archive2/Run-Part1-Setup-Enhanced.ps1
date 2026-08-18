# Master Script - Part 1: Initial Setup (Enhanced with Logging & Retry)
# Runs Steps 01-03 in succession
# - Prerequisites and Configuration
# - SharePoint Site and List Provisioning
# - Shared Mailbox Creation

$ErrorActionPreference = "Continue"

# Import common functions
. "$PSScriptRoot\Common-Functions.ps1"

# Initialize logging
$logFile = Initialize-Logging -LogPrefix "Part1-Setup"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  MFA ONBOARDING - PART 1: INITIAL SETUP" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

Write-Log "Part 1 deployment started" -Level INFO

Write-Host "This script will run the following steps:" -ForegroundColor Yellow
Write-Host "  01 - Prerequisites & Configuration" -ForegroundColor Gray
Write-Host "  02 - SharePoint Site & List" -ForegroundColor Gray
Write-Host "  03 - Shared Mailbox" -ForegroundColor Gray
Write-Host "`nLog file: $logFile`n" -ForegroundColor Gray

$confirmation = Read-Host "Continue? (Y/N)"
if ($confirmation -notmatch '^[Yy]') {
    Write-Log "Deployment cancelled by user" -Level WARNING
    Write-Host "Cancelled by user." -ForegroundColor Yellow
    exit 0
}

$stepResults = @{}

# Step 01 - Prerequisites
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 01 - PREREQUISITES" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

$stepResults["Step 01: Prerequisites"] = Invoke-WithRetry -Critical -StepName "Prerequisites & Configuration" -ScriptBlock {
    & "$PSScriptRoot\01-Install-Prerequisites.ps1"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        throw "Script exited with code $LASTEXITCODE"
    }
}

Start-Sleep -Seconds 3

# Step 02 - SharePoint
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 02 - SHAREPOINT PROVISIONING" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

$stepResults["Step 02: SharePoint Provisioning"] = Invoke-WithRetry -Critical -StepName "SharePoint Site & List" -ScriptBlock {
    & "$PSScriptRoot\02-Provision-SharePoint.ps1"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        throw "Script exited with code $LASTEXITCODE"
    }
}

Start-Sleep -Seconds 3

# Step 03 - Shared Mailbox
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "RUNNING STEP 03 - SHARED MAILBOX" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

$stepResults["Step 03: Shared Mailbox"] = Invoke-WithRetry -StepName "Shared Mailbox Creation" -ScriptBlock {
    & "$PSScriptRoot\03-Create-Shared-Mailbox.ps1"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        throw "Script exited with code $LASTEXITCODE"
    }
}

# Generate Summary Report
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GENERATING SUMMARY REPORT" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

$duration = (Get-Date) - $script:StartTime
$summaryFile = Join-Path $PSScriptRoot "logs\Part1-Setup-Summary_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').txt"
$configFile = Join-Path $PSScriptRoot "mfa-config.ini"

$summary = @"
================================================================================
    MFA ONBOARDING - PART 1 SETUP SUMMARY
================================================================================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Duration: $($duration.ToString('hh\:mm\:ss'))
Log File: $logFile

================================================================================
DEPLOYMENT STATUS
================================================================================
"@

$allSuccess = $true
foreach ($step in $stepResults.Keys | Sort-Object) {
    $status = if ($stepResults[$step]) { "✓ SUCCESS" } else { "✗ FAILED" }
    $color = if ($stepResults[$step]) { "Green" } else { "Red" }
    $summary += "`n$step : $status"
    Write-Host "$step : $status" -ForegroundColor $color
    if (-not $stepResults[$step]) { $allSuccess = $false }
}

if (Test-Path $configFile) {
    $config = Get-IniContent -Path $configFile
    $summary += @"


================================================================================
CONFIGURED RESOURCES
================================================================================
Tenant ID         : $($config["Tenant"]["TenantId"])
SharePoint Site   : $($config["SharePoint"]["SiteUrl"])
SharePoint List   : $($config["SharePoint"]["ListTitle"])
App Registration  : $($config["SharePoint"]["AppRegName"])
Client ID         : $($config["SharePoint"]["ClientId"])
Certificate       : $($config["SharePoint"]["CertificatePath"])
Security Group    : $($config["Security"]["MFAGroupName"])
Group ID          : $($config["Security"]["MFAGroupId"])
Shared Mailbox    : $($config["Email"]["NoReplyMailbox"])
Mailbox Delegate  : $($config["Email"]["MailboxDelegate"])

================================================================================
VERIFICATION STEPS
================================================================================
1. Check SharePoint Site
   URL: $($config["SharePoint"]["SiteUrl"])
   - Verify site was created successfully
   - Check that "$($config["SharePoint"]["ListTitle"])" list exists
   - Confirm list has required columns

2. Check Security Group
   URL: https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$($config["Security"]["MFAGroupId"])
   - Verify group was created
   - Note the group ID for Conditional Access policies

3. Check Shared Mailbox
   URL: https://admin.microsoft.com/AdminPortal/Home#/mailboxes
   - Search for: $($config["Email"]["NoReplyMailbox"])
   - Verify mailbox exists and delegate has permission

================================================================================
NEXT STEPS
================================================================================
1. Review configuration file: mfa-config.ini
2. Verify resources were created in Microsoft 365 admin center
3. Run Part 2 deployment: .\Run-Part2-Deploy-Enhanced.ps1
4. Check deployment log: $logFile

================================================================================
"@
}

# Save summary to file
$summary | Out-File -FilePath $summaryFile -Encoding UTF8
Write-Host "`n$summary`n"
Write-Log "Summary report saved to: $summaryFile" -Level SUCCESS

# Final status
if ($allSuccess) {
    Write-Host "`n✓ PART 1 COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))`n" -ForegroundColor Gray
    Write-Log "Part 1 deployment completed successfully" -Level SUCCESS
    exit 0
} else {
    Write-Host "`n✗ PART 1 COMPLETED WITH ERRORS" -ForegroundColor Red
    Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
    Write-Host "Check log file: $logFile`n" -ForegroundColor Yellow
    Write-Log "Part 1 deployment completed with errors" -Level ERROR
    exit 1
}
