# Step 05 - Configure TAP Function App settings and deploy code

$ErrorActionPreference = 'Stop'
$configFile = "$PSScriptRoot\tap-config.ini"
$functionCodePath = "$PSScriptRoot\function-code"
$zipPath = "$PSScriptRoot\function-deploy.zip"

function Get-IniContent {
    param([string]$Path)

    $ini = @{}
    $section = ''
    switch -regex -file $Path {
        '^\[(.+)\]$' {
            $section = $matches[1]
            $ini[$section] = @{}
        }
        '(.+?)\s*=\s*(.*)' {
            $name = $matches[1]
            $value = $matches[2]
            $ini[$section][$name] = $value
        }
    }

    return $ini
}

if (-not (Test-Path $configFile)) {
    throw "Config file not found: $configFile"
}

$config = Get-IniContent -Path $configFile
$resourceGroup = $config['Azure']['ResourceGroup']
$functionAppName = $config['Azure']['FunctionAppName']
$queueName = $config['Azure']['QueueName']
$tenantId = $config['Tenant']['TenantId']
$mailAuthMode = if ($config['MailAuth']['Mode']) { $config['MailAuth']['Mode'] } else { 'ManagedIdentity' }
$mailAppClientId = $config['MailAuth']['ServicePrincipalClientId']
$mailAppObjectId = $config['MailAuth']['ServicePrincipalObjectId']
$mailPolicyGroupAddress = $config['MailAuth']['PolicyGroupAddress']

$tapConfig = [ordered]@{
    TenantId = $tenantId
    DefaultTenantDomain = $config['TAP']['DefaultTenantDomain']
    DefaultGroupObjectId = $config['TAP']['DefaultGroupObjectId']
    AdminGroupObjectId = $config['TAP']['AdminGroupObjectId']
    SharedMailboxAddress = $config['Email']['SharedMailboxAddress']
    SharePointSiteId = $config['SharePoint']['SiteId']
    SharePointListId = $config['SharePoint']['ListId']
    TapLifetimeDays = [int]$config['TAP']['TapLifetimeDays']
    TapIsUsableOnce = ($config['TAP']['TapIsUsableOnce'] -eq 'true')
    MaximumTapAttempts = [int]$config['TAP']['MaximumTapAttempts']
    MaximumOnboardingDays = [int]$config['TAP']['MaximumOnboardingDays']
    RequireApprovalAfterAttempt = [int]$config['TAP']['RequireApprovalAfterAttempt']
    DisableAutomaticReissue = ($config['TAP']['DisableAutomaticReissue'] -eq 'true')
    ApprovedPasskeyMethodTypes = @($config['TAP']['ApprovedPasskeyMethodTypes'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    CompanyDisplayName = $config['Email']['CompanyDisplayName']
    SupportEmailAddress = $config['Email']['SupportEmailAddress']
    ApplicationLinks = [ordered]@{
        AuthenticatorDownloadUrlIOS = $config['ApplicationLinks']['AuthenticatorDownloadUrlIOS']
        AuthenticatorDownloadUrlAndroid = $config['ApplicationLinks']['AuthenticatorDownloadUrlAndroid']
        MySecurityInfoUrl = $config['ApplicationLinks']['MySecurityInfoUrl']
        Microsoft365PortalUrl = $config['ApplicationLinks']['Microsoft365PortalUrl']
        TeamsUrl = $config['ApplicationLinks']['TeamsUrl']
        OutlookUrl = $config['ApplicationLinks']['OutlookUrl']
        SharePointUrl = $config['ApplicationLinks']['SharePointUrl']
        PasskeySetupGuideUrl = $config['ApplicationLinks']['PasskeySetupGuideUrl']
    }
    EmailTemplatePath = $config['Email']['EmailTemplatePath']
}

$tapConfigJson = $tapConfig | ConvertTo-Json -Depth 20 -Compress

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Compress-Archive -Path "$functionCodePath\*" -DestinationPath $zipPath -Force

az functionapp config appsettings set `
    --resource-group $resourceGroup `
    --name $functionAppName `
    --settings `
        "TAP_CONFIG_JSON=$tapConfigJson" `
        "STORAGE_QUEUE_NAME=$queueName" `
        "ADMIN_PORTAL_ORIGIN=*" `
        "MAIL_AUTH_MODE=$mailAuthMode" `
        "MAIL_APP_CLIENT_ID=$mailAppClientId" `
        "MAIL_APP_OBJECT_ID=$mailAppObjectId" `
        "MAIL_POLICY_GROUP_ADDRESS=$mailPolicyGroupAddress" | Out-Null

$deploy = az functionapp deployment source config-zip `
    --resource-group $resourceGroup `
    --name $functionAppName `
    --src $zipPath 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host $deploy -ForegroundColor Red
    throw 'Function deployment failed.'
}

Remove-Item $zipPath -Force
Write-Host 'Step 05 complete: Function deployed and app settings configured.' -ForegroundColor Green
