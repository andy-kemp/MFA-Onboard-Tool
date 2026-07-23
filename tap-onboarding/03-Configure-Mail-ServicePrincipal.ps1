# Step 03 - Configure service principal auth for shared mailbox TAP email
# Supports two modes:
#   1) ManagedIdentity: grant Mail.Send app role to Function App managed identity service principal
#   2) AppRegistration: create or reuse dedicated app registration/service principal and grant Mail.Send
#
# Optional: create Exchange Online application access policy so mail send is scoped to a mailbox group.

$ErrorActionPreference = 'Stop'
$configFile = "$PSScriptRoot\tap-config.ini"

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

function Set-IniValue {
    param(
        [string]$Path,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $ini = Get-IniContent -Path $Path

    if (-not $ini.ContainsKey($Section)) {
        $ini[$Section] = @{}
    }

    $ini[$Section][$Key] = $Value

    $out = @()
    foreach ($sectionName in $ini.Keys) {
        $out += "[$sectionName]"
        foreach ($keyName in $ini[$sectionName].Keys) {
            $out += "$keyName=$($ini[$sectionName][$keyName])"
        }
        $out += ''
    }

    Set-Content -Path $Path -Value ($out -join "`r`n") -Encoding UTF8
}

function ConvertTo-Bool {
    param([string]$Value, [bool]$Default = $false)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    $lower = $Value.Trim().ToLowerInvariant()
    return $lower -in @('true', '1', 'yes', 'y')
}

function Ensure-GraphMailSendAppRoleAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetServicePrincipalObjectId
    )

    # Microsoft Graph appId and Mail.Send application appRoleId
    $graphAppId = '00000003-0000-0000-c000-000000000000'
    $mailSendAppRoleId = 'b633e1c5-b582-4048-a93e-9f11b44c7e96'

    $graphSpJson = az ad sp show --id $graphAppId | ConvertFrom-Json
    $graphSpObjectId = $graphSpJson.id

    $existingJson = az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$TargetServicePrincipalObjectId/appRoleAssignments" | ConvertFrom-Json
    $hasRole = $false

    foreach ($assignment in $existingJson.value) {
        if ($assignment.resourceId -eq $graphSpObjectId -and $assignment.appRoleId -eq $mailSendAppRoleId) {
            $hasRole = $true
            break
        }
    }

    if ($hasRole) {
        Write-Host 'Mail.Send application role already assigned.' -ForegroundColor Green
        return
    }

    $body = @{
        principalId = $TargetServicePrincipalObjectId
        resourceId = $graphSpObjectId
        appRoleId = $mailSendAppRoleId
    } | ConvertTo-Json

    $tmp = [System.IO.Path]::GetTempFileName()
    $body | Set-Content -Path $tmp -Encoding UTF8

    try {
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$TargetServicePrincipalObjectId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$tmp" | Out-Null
        Write-Host 'Mail.Send application role assigned.' -ForegroundColor Green
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-ExchangeApplicationAccessPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$SharedMailboxAddress,
        [Parameter(Mandatory = $true)]
        [string]$PolicyGroupName,
        [string]$PolicyGroupAddress,
        [string]$PolicyDescription = 'Restrict TAP mail sender app to TAP shared mailbox'
    )

    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force'
    }

    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    Write-Host 'Connecting to Exchange Online...' -ForegroundColor Yellow
    Connect-ExchangeOnline -ShowBanner:$false

    try {
        $domain = $SharedMailboxAddress.Split('@')[1]

        if ([string]::IsNullOrWhiteSpace($PolicyGroupAddress)) {
            $alias = 'tapmailscope'
            $PolicyGroupAddress = "$alias@$domain"
        }

        $group = Get-DistributionGroup -Identity $PolicyGroupAddress -ErrorAction SilentlyContinue
        if (-not $group) {
            $alias = $PolicyGroupAddress.Split('@')[0]
            New-DistributionGroup -Name $PolicyGroupName -Alias $alias -Type Security -PrimarySmtpAddress $PolicyGroupAddress | Out-Null
            Write-Host "Created mail-enabled security group: $PolicyGroupAddress" -ForegroundColor Green
        }
        else {
            Write-Host "Using existing mail-enabled security group: $PolicyGroupAddress" -ForegroundColor Green
        }

        $member = Get-DistributionGroupMember -Identity $PolicyGroupAddress -ResultSize Unlimited | Where-Object { $_.PrimarySmtpAddress -eq $SharedMailboxAddress }
        if (-not $member) {
            Add-DistributionGroupMember -Identity $PolicyGroupAddress -Member $SharedMailboxAddress
            Write-Host "Added mailbox $SharedMailboxAddress to policy scope group." -ForegroundColor Green
        }

        $existingPolicy = Get-ApplicationAccessPolicy -ErrorAction SilentlyContinue | Where-Object {
            $_.AppId -eq $AppId -and $_.PolicyScopeGroupId -eq $PolicyGroupAddress
        }

        if (-not $existingPolicy) {
            New-ApplicationAccessPolicy -AppId $AppId -PolicyScopeGroupId $PolicyGroupAddress -AccessRight RestrictAccess -Description $PolicyDescription | Out-Null
            Write-Host 'Created Exchange application access policy.' -ForegroundColor Green
        }
        else {
            Write-Host 'Exchange application access policy already exists.' -ForegroundColor Green
        }

        Write-Host ''
        Write-Host 'Policy test command (run if needed):' -ForegroundColor Cyan
        Write-Host "Test-ApplicationAccessPolicy -Identity $SharedMailboxAddress -AppId $AppId" -ForegroundColor White

        return $PolicyGroupAddress
    }
    finally {
        Disconnect-ExchangeOnline -Confirm:$false
    }
}

if (-not (Test-Path $configFile)) {
    throw "Config file not found: $configFile"
}

$config = Get-IniContent -Path $configFile

$tenantId = $config['Tenant']['TenantId']
$subscriptionId = $config['Tenant']['SubscriptionId']
$resourceGroup = $config['Azure']['ResourceGroup']
$functionAppName = $config['Azure']['FunctionAppName']
$sharedMailboxAddress = $config['Email']['SharedMailboxAddress']

$mailAuthMode = if ($config['MailAuth']['Mode']) { $config['MailAuth']['Mode'] } else { 'ManagedIdentity' }
$appDisplayName = if ($config['MailAuth']['ServicePrincipalAppDisplayName']) { $config['MailAuth']['ServicePrincipalAppDisplayName'] } else { 'TAP-Onboarding-Mailer' }
$clientId = $config['MailAuth']['ServicePrincipalClientId']
$spObjectId = $config['MailAuth']['ServicePrincipalObjectId']
$usePolicy = ConvertTo-Bool -Value $config['MailAuth']['UseApplicationAccessPolicy'] -Default $true
$policyGroupName = if ($config['MailAuth']['PolicyGroupName']) { $config['MailAuth']['PolicyGroupName'] } else { 'TAP Mail Scope' }
$policyGroupAddress = $config['MailAuth']['PolicyGroupAddress']
$policyDescription = if ($config['MailAuth']['PolicyDescription']) { $config['MailAuth']['PolicyDescription'] } else { 'Restrict TAP mail sender app to TAP shared mailbox' }

if ([string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'TenantId and SubscriptionId are required in tap-config.ini'
}

if ([string]::IsNullOrWhiteSpace($sharedMailboxAddress)) {
    throw 'Email.SharedMailboxAddress is required in tap-config.ini'
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Step 03 - Configure Mail Service Principal' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Mode: $mailAuthMode"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    az login --tenant $tenantId | Out-Null
}
az account set --subscription $subscriptionId | Out-Null

$effectiveAppId = $null
$effectiveSpObjectId = $null

if ($mailAuthMode -ieq 'ManagedIdentity') {
    if ([string]::IsNullOrWhiteSpace($resourceGroup) -or [string]::IsNullOrWhiteSpace($functionAppName)) {
        throw 'Azure.ResourceGroup and Azure.FunctionAppName are required for ManagedIdentity mode.'
    }

    $functionIdentity = az functionapp identity show --resource-group $resourceGroup --name $functionAppName | ConvertFrom-Json
    if (-not $functionIdentity.principalId) {
        throw 'Function App managed identity not found. Enable system-assigned identity first.'
    }

    $effectiveSpObjectId = $functionIdentity.principalId
    $effectiveAppId = $functionIdentity.clientId

    Write-Host "Using Function App managed identity clientId: $effectiveAppId" -ForegroundColor Gray
    Ensure-GraphMailSendAppRoleAssignment -TargetServicePrincipalObjectId $effectiveSpObjectId
}
elseif ($mailAuthMode -ieq 'AppRegistration') {
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        Write-Host "Creating app registration: $appDisplayName" -ForegroundColor Yellow
        $newApp = az ad app create --display-name $appDisplayName | ConvertFrom-Json
        $clientId = $newApp.appId
        Set-IniValue -Path $configFile -Section 'MailAuth' -Key 'ServicePrincipalClientId' -Value $clientId
    }
    else {
        Write-Host "Using configured app registration clientId: $clientId" -ForegroundColor Gray
    }

    $sp = az ad sp show --id $clientId 2>$null
    if (-not $sp) {
        $sp = az ad sp create --id $clientId
    }

    $spObj = $sp | ConvertFrom-Json
    $spObjectId = $spObj.id

    Set-IniValue -Path $configFile -Section 'MailAuth' -Key 'ServicePrincipalObjectId' -Value $spObjectId

    $effectiveAppId = $clientId
    $effectiveSpObjectId = $spObjectId

    Ensure-GraphMailSendAppRoleAssignment -TargetServicePrincipalObjectId $effectiveSpObjectId

    Write-Host ''
    Write-Host 'Granting admin consent for the app registration...' -ForegroundColor Yellow
    az ad app permission admin-consent --id $effectiveAppId | Out-Null
}
else {
    throw "Unsupported MailAuth.Mode '$mailAuthMode'. Supported values: ManagedIdentity, AppRegistration"
}

if ($usePolicy) {
    $resolvedGroupAddress = Ensure-ExchangeApplicationAccessPolicy `
        -AppId $effectiveAppId `
        -SharedMailboxAddress $sharedMailboxAddress `
        -PolicyGroupName $policyGroupName `
        -PolicyGroupAddress $policyGroupAddress `
        -PolicyDescription $policyDescription

    Set-IniValue -Path $configFile -Section 'MailAuth' -Key 'PolicyGroupAddress' -Value $resolvedGroupAddress
}

Set-IniValue -Path $configFile -Section 'MailAuth' -Key 'ServicePrincipalClientId' -Value $effectiveAppId
if ($effectiveSpObjectId) {
    Set-IniValue -Path $configFile -Section 'MailAuth' -Key 'ServicePrincipalObjectId' -Value $effectiveSpObjectId
}

Write-Host ''
Write-Host 'Step 03 complete.' -ForegroundColor Green
Write-Host "Mail sender app/clientId: $effectiveAppId" -ForegroundColor Green
Write-Host 'Next: run Step 05 to update Function App settings.' -ForegroundColor Green
