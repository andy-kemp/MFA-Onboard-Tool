# Complete MFA Onboarding Deployment - All Steps (01-08 + Fixes)
# Runs the entire deployment from start to finish

$ErrorActionPreference = "Continue"

# Import common functions
if (Test-Path "$PSScriptRoot\Common-Functions.ps1") {
    . "$PSScriptRoot\Common-Functions.ps1"
    $logFile = Initialize-Logging -LogPrefix "Complete-Deployment"
} else {
    $logFile = "$PSScriptRoot\logs\Complete-Deployment_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
    if (-not (Test-Path "$PSScriptRoot\logs")) {
        New-Item -ItemType Directory -Path "$PSScriptRoot\logs" -Force | Out-Null
    }
    function Write-Log { param($Message, $Level = "INFO") }
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  MFA ONBOARDING - COMPLETE DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

Write-Log "Complete deployment started" -Level INFO

Write-Host "This script will run ALL deployment steps:" -ForegroundColor Yellow
Write-Host "`nPART 1 - FOUNDATION:" -ForegroundColor Cyan
Write-Host "  01 - Install Prerequisites" -ForegroundColor Gray
Write-Host "  02 - Provision SharePoint Site & List" -ForegroundColor Gray
Write-Host "  03 - Create Shared Mailbox" -ForegroundColor Gray
Write-Host "`nPART 2 - AZURE DEPLOYMENT:" -ForegroundColor Cyan
Write-Host "  04 - Create Azure Resources" -ForegroundColor Gray
Write-Host "  05 - Configure Function App" -ForegroundColor Gray
Write-Host "  06 - Deploy Invitation Logic App" -ForegroundColor Gray
Write-Host "  07 - Deploy Upload Portal" -ForegroundColor Gray
Write-Host "  08 - Setup Email Reports (optional)" -ForegroundColor Gray
Write-Host "`nPART 3 - FIXES & PERMISSIONS:" -ForegroundColor Cyan
Write-Host "  • Function Authentication" -ForegroundColor Gray
Write-Host "  • Graph API Permissions" -ForegroundColor Gray
Write-Host "  • Logic App Permissions" -ForegroundColor Gray
Write-Host "`nLog file: $logFile`n" -ForegroundColor Gray

$confirmation = Read-Host "Continue with complete deployment? (Y/N)"
if ($confirmation -notmatch '^[Yy]') {
    Write-Log "Deployment cancelled by user" -Level WARNING
    Write-Host "Cancelled by user." -ForegroundColor Yellow
    exit 0
}

$script:StartTime = Get-Date
$stepResults = @{}

# Helper function for retry
function Invoke-DeploymentStep {
    param(
        [string]$StepNumber,
        [string]$StepName,
        [string]$ScriptPath,
        [switch]$Critical
    )
    
    Write-Host "`n============================================" -ForegroundColor Magenta
    Write-Host "STEP $StepNumber - $StepName" -ForegroundColor Magenta
    Write-Host "============================================`n" -ForegroundColor Magenta
    
    $maxRetries = if ($Critical) { 3 } else { 2 }
    $retryCount = 0
    $success = $false
    
    while ($retryCount -lt $maxRetries -and -not $success) {
        try {
            if ($retryCount -gt 0) {
                Write-Host "`nRetry attempt $retryCount of $($maxRetries - 1)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            }
            
            & $ScriptPath
            
            if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
                $success = $true
                Write-Host "✓ Step $StepNumber completed successfully" -ForegroundColor Green
            } else {
                throw "Script exited with code $LASTEXITCODE"
            }
        }
        catch {
            $retryCount++
            Write-Host "✗ Error in Step ${StepNumber}: $($_.Exception.Message)" -ForegroundColor Red
            
            if ($retryCount -ge $maxRetries) {
                if ($Critical) {
                    Write-Host "✗ Critical step failed. Cannot continue." -ForegroundColor Red
                    return $false
                } else {
                    Write-Host "⚠ Step failed but will continue..." -ForegroundColor Yellow
                    return $true  # Continue even if non-critical fails
                }
            }
        }
    }
    
    return $success
}

# ============================================
# PART 1 - FOUNDATION
# ============================================

Write-Host "`n" -NoNewline
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "PART 1 - FOUNDATION SETUP" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Step 01 - Prerequisites
$stepResults["01: Install Prerequisites"] = Invoke-DeploymentStep `
    -StepNumber "01" `
    -StepName "INSTALL PREREQUISITES" `
    -ScriptPath "$PSScriptRoot\01-Install-Prerequisites.ps1" `
    -Critical

if (-not $stepResults["01: Install Prerequisites"]) {
    Write-Host "`n✗ Cannot continue without prerequisites installed." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3

# Step 02 - SharePoint
$stepResults["02: Provision SharePoint"] = Invoke-DeploymentStep `
    -StepNumber "02" `
    -StepName "PROVISION SHAREPOINT" `
    -ScriptPath "$PSScriptRoot\02-Provision-SharePoint.ps1" `
    -Critical

if (-not $stepResults["02: Provision SharePoint"]) {
    Write-Host "`n✗ Cannot continue without SharePoint site and list." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3

# Step 03 - Shared Mailbox
$stepResults["03: Create Shared Mailbox"] = Invoke-DeploymentStep `
    -StepNumber "03" `
    -StepName "CREATE SHARED MAILBOX" `
    -ScriptPath "$PSScriptRoot\03-Create-Shared-Mailbox.ps1"

Start-Sleep -Seconds 3

# ============================================
# PART 2 - AZURE DEPLOYMENT
# ============================================

Write-Host "`n" -NoNewline
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "PART 2 - AZURE DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Step 04 - Azure Resources
$stepResults["04: Azure Resources"] = Invoke-DeploymentStep `
    -StepNumber "04" `
    -StepName "CREATE AZURE RESOURCES" `
    -ScriptPath "$PSScriptRoot\04-Create-Azure-Resources.ps1" `
    -Critical

if (-not $stepResults["04: Azure Resources"]) {
    Write-Host "`n✗ Cannot continue without Azure resources." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3

# Step 05 - Function App
$stepResults["05: Function App Configuration"] = Invoke-DeploymentStep `
    -StepNumber "05" `
    -StepName "CONFIGURE FUNCTION APP" `
    -ScriptPath "$PSScriptRoot\05-Configure-Function-App.ps1" `
    -Critical

if (-not $stepResults["05: Function App Configuration"]) {
    Write-Host "`n✗ Cannot continue without Function App." -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3

# Step 06 - Logic App (Invitations)
$stepResults["06: Logic App Deployment"] = Invoke-DeploymentStep `
    -StepNumber "06" `
    -StepName "DEPLOY INVITATION LOGIC APP" `
    -ScriptPath "$PSScriptRoot\06-Deploy-Logic-App.ps1"

Start-Sleep -Seconds 3

# Step 07 - Upload Portal
$stepResults["07: Upload Portal"] = Invoke-DeploymentStep `
    -StepNumber "07" `
    -StepName "DEPLOY UPLOAD PORTAL" `
    -ScriptPath "$PSScriptRoot\07-Deploy-Upload-Portal1.ps1"

Start-Sleep -Seconds 3

# Step 08 - Email Reports (Optional)
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "STEP 08 - EMAIL REPORTS SETUP (OPTIONAL)" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

Write-Host "Would you like to set up automated daily/weekly email reports? (Y/N)" -ForegroundColor Yellow
$setupReports = Read-Host "Choice"
if ($setupReports -match '^[Yy]') {
    $stepResults["08: Email Reports Setup"] = Invoke-DeploymentStep `
        -StepNumber "08" `
        -StepName "SETUP EMAIL REPORTS" `
        -ScriptPath "$PSScriptRoot\08-Deploy-Email-Reports.ps1"
} else {
    Write-Host "⏭️  Skipping email reports setup (you can run 08-Deploy-Email-Reports.ps1 later)" -ForegroundColor Gray
    $stepResults["08: Email Reports Setup"] = $true
}

Start-Sleep -Seconds 3

# ============================================
# PART 3 - FIXES & PERMISSIONS
# ============================================

Write-Host "`n" -NoNewline
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "PART 3 - FIXES & PERMISSIONS" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Fix - Function Authentication
$stepResults["Fix: Function Authentication"] = Invoke-DeploymentStep `
    -StepNumber "FIX-1" `
    -StepName "FUNCTION AUTHENTICATION" `
    -ScriptPath "$PSScriptRoot\Fix-Function-Auth.ps1"

Start-Sleep -Seconds 3

# Fix - Graph Permissions (includes all Logic Apps now)
$stepResults["Fix: Graph Permissions"] = Invoke-DeploymentStep `
    -StepNumber "FIX-2" `
    -StepName "GRAPH API PERMISSIONS" `
    -ScriptPath "$PSScriptRoot\Fix-Graph-Permissions.ps1"

Start-Sleep -Seconds 3

# Fix - Logic App Permissions Check
if (Test-Path "$PSScriptRoot\Check-LogicApp-Permissions.ps1") {
    $stepResults["Fix: Logic App Permissions"] = Invoke-DeploymentStep `
        -StepNumber "FIX-3" `
        -StepName "LOGIC APP PERMISSIONS CHECK" `
        -ScriptPath "$PSScriptRoot\Check-LogicApp-Permissions.ps1"
} else {
    Write-Host "⏭️  Check-LogicApp-Permissions.ps1 not found, skipping..." -ForegroundColor Gray
    $stepResults["Fix: Logic App Permissions"] = $true
}

# ============================================
# GENERATE SUMMARY & DISPLAY URLS
# ============================================

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GENERATING DEPLOYMENT SUMMARY" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

$configFile = Join-Path $PSScriptRoot "mfa-config.ini"

# Read config for final URLs
function Get-IniContent {
    param([string]$Path)
    $ini = @{}
    $section = ""
    if (Test-Path $Path) {
        switch -regex -file $Path {
            "^\[(.+)\]$" {
                $section = $matches[1]
                $ini[$section] = @{}
            }
            "(.+?)\s*=\s*(.*)" {
                $name = $matches[1]
                $value = $matches[2]
                $ini[$section][$name] = $value
            }
        }
    }
    return $ini
}

$config = Get-IniContent -Path $configFile

# Create summary file
$summaryFile = Join-Path $PSScriptRoot "logs\COMPLETE-DEPLOYMENT-SUMMARY_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').txt"
$summaryContent = @"
========================================
MFA ONBOARDING - COMPLETE DEPLOYMENT
========================================
Deployment Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Duration: $((Get-Date) - $script:StartTime)

STEP RESULTS:
----------------------------------------
"@

foreach ($step in $stepResults.Keys | Sort-Object) {
    $status = if ($stepResults[$step]) { "✓ SUCCESS" } else { "✗ FAILED" }
    $summaryContent += "`n$step : $status"
}

$summaryContent += @"


CONFIGURATION SUMMARY:
----------------------------------------
Tenant ID        : $($config['Tenant']['TenantId'])
Subscription ID  : $($config['Tenant']['SubscriptionId'])
Resource Group   : $($config['Azure']['ResourceGroup'])
Region           : $($config['Azure']['Region'])

SharePoint Site  : $($config['SharePoint']['SiteUrl'])
SharePoint List  : $($config['SharePoint']['ListTitle'])
List ID          : $($config['SharePoint']['ListId'])

Function App     : $($config['Azure']['FunctionAppName'])
Logic App        : $($config['LogicApp']['LogicAppName'])
Reports Logic App: $($config['EmailReports']['LogicAppName'])

No-Reply Mailbox : $($config['Email']['NoReplyMailbox'])
MFA Group        : $($config['Security']['MFAGroupName'])
Upload Portal ID : $($config['UploadPortal']['ClientId'])

========================================
"@

$summaryContent | Set-Content $summaryFile -Force

# Final status
$allSuccess = $true
$criticalFailed = $false
foreach ($key in $stepResults.Keys) {
    if (-not $stepResults[$key]) {
        $allSuccess = $false
        if ($key -match "^(01|02|04|05):") {
            $criticalFailed = $true
        }
    }
}

$duration = (Get-Date) - $script:StartTime

if ($allSuccess) {
    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host "  ✓ DEPLOYMENT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "============================================`n" -ForegroundColor Green
} elseif ($criticalFailed) {
    Write-Host "`n============================================" -ForegroundColor Red
    Write-Host "  ✗ DEPLOYMENT FAILED - CRITICAL ERRORS" -ForegroundColor Red
    Write-Host "============================================`n" -ForegroundColor Red
} else {
    Write-Host "`n============================================" -ForegroundColor Yellow
    Write-Host "  ⚠ DEPLOYMENT COMPLETED WITH WARNINGS" -ForegroundColor Yellow
    Write-Host "============================================`n" -ForegroundColor Yellow
}

Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray

# Display Key URLs
Write-Host "`n📍 KEY URLs - COPY THESE FOR QUICK ACCESS:" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Write-Host "`n📋 SHAREPOINT LIST:" -ForegroundColor Yellow
$siteUrl = $config["SharePoint"]["SiteUrl"]
$listTitle = $config["SharePoint"]["ListTitle"]
$listId = $config["SharePoint"]["ListId"]
if ($siteUrl -and $listTitle) {
    $listUrl = "$siteUrl/Lists/$($listTitle -replace ' ','%20')/AllItems.aspx"
    Write-Host "  $listUrl" -ForegroundColor White
} elseif ($siteUrl -and $listId) {
    $listUrl = "$siteUrl/_layouts/15/listform.aspx?ListId=$listId"
    Write-Host "  $listUrl" -ForegroundColor White
} else {
    Write-Host "  (Not configured yet)" -ForegroundColor Gray
}

Write-Host "`n🌐 UPLOAD PORTAL:" -ForegroundColor Yellow
$portalPath = "$env:TEMP\upload-portal-deployed.html"
if (Test-Path $portalPath) {
    Write-Host "  file:///$($portalPath -replace '\\','/')" -ForegroundColor White
    Write-Host "  Local path: $portalPath" -ForegroundColor Gray
} else {
    Write-Host "  (Portal not deployed yet)" -ForegroundColor Gray
}

Write-Host "`n⚡ FUNCTION APP:" -ForegroundColor Yellow
$functionAppName = $config["Azure"]["FunctionAppName"]
if ($functionAppName) {
    Write-Host "  https://$functionAppName.azurewebsites.net" -ForegroundColor White
    Write-Host "  Enrol endpoint: https://$functionAppName.azurewebsites.net/api/enrol" -ForegroundColor Gray
} else {
    Write-Host "  (Function App not created yet)" -ForegroundColor Gray
}

Write-Host "`n📧 LOGIC APPS:" -ForegroundColor Yellow
$logicAppName = $config["LogicApp"]["LogicAppName"]
$reportsLogicAppName = $config["EmailReports"]["LogicAppName"]
$resourceGroup = $config["Azure"]["ResourceGroup"]
$subscriptionId = $config["Tenant"]["SubscriptionId"]

if ($logicAppName -and $resourceGroup -and $subscriptionId) {
    Write-Host "  Invitations: https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/$logicAppName" -ForegroundColor White
} else {
    Write-Host "  Invitations: (Not deployed yet)" -ForegroundColor Gray
}

if ($reportsLogicAppName -and $resourceGroup -and $subscriptionId) {
    Write-Host "  Reports    : https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/$reportsLogicAppName" -ForegroundColor White
} else {
    Write-Host "  Reports    : (Not deployed)" -ForegroundColor Gray
}

Write-Host "`n============================================" -ForegroundColor Cyan

Write-Host "`n📄 Deployment Files:" -ForegroundColor Yellow
Write-Host "  Configuration : $configFile" -ForegroundColor Gray
Write-Host "  Summary       : $summaryFile" -ForegroundColor Gray
Write-Host "  Log           : $logFile" -ForegroundColor Gray

if ($allSuccess -or -not $criticalFailed) {
    Write-Host "`n✅ NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Open the Upload Portal URL above" -ForegroundColor White
    Write-Host "  2. Upload test users (CSV or manual entry)" -ForegroundColor White
    Write-Host "  3. Verify invitation emails are sent immediately" -ForegroundColor White
    Write-Host "  4. Click enrollment link and verify MFA group addition" -ForegroundColor White
    
    Write-Host "`n⚠️  MANUAL STEPS REQUIRED:" -ForegroundColor Yellow
    Write-Host "  • Authorize API connections in Azure Portal:" -ForegroundColor Gray
    Write-Host "    - Resource Groups > $resourceGroup > Connections" -ForegroundColor Gray
    Write-Host "    - Authorize: sharepointonline, office365, azuread" -ForegroundColor Gray
}

if ($criticalFailed) {
    Write-Host "`n❌ CRITICAL ERRORS OCCURRED:" -ForegroundColor Red
    Write-Host "  Review the log file for details: $logFile" -ForegroundColor Gray
    Write-Host "  Fix the issues and run individual scripts or rerun this script" -ForegroundColor Gray
}

Write-Host ""
Write-Log "Complete deployment finished" -Level INFO

if ($criticalFailed) {
    exit 1
} else {
    exit 0
}
