# Step 04 - Create TAP onboarding Azure resources from Bicep

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

if (-not (Test-Path $configFile)) {
    throw "Config file not found: $configFile"
}

$config = Get-IniContent -Path $configFile
$subscriptionId = $config['Tenant']['SubscriptionId']
$resourceGroup = $config['Azure']['ResourceGroup']
$region = $config['Azure']['Region']
$storageAccountName = $config['Azure']['StorageAccountName']
$functionAppName = $config['Azure']['FunctionAppName']
$queueName = $config['Azure']['QueueName']
$staticWebAppName = $config['StaticWebApp']['AppName']

if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($resourceGroup)) {
    throw 'Tenant.SubscriptionId and Azure.ResourceGroup are required in tap-config.ini'
}

az account set --subscription $subscriptionId | Out-Null

if (-not (az group exists --name $resourceGroup | ConvertFrom-Json)) {
    az group create --name $resourceGroup --location $region | Out-Null
}

az deployment group create `
    --resource-group $resourceGroup `
    --template-file "$PSScriptRoot\infra\main.bicep" `
    --parameters storageAccountName=$storageAccountName functionAppName=$functionAppName staticWebAppName=$staticWebAppName queueName=$queueName | Out-Null

Write-Host 'Step 04 complete: Resources deployed.' -ForegroundColor Green
