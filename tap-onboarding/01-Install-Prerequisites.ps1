# Step 01 - Install TAP onboarding prerequisites

$ErrorActionPreference = 'Stop'

$requiredModules = @(
    'Az.Accounts',
    'Az.Resources',
    'ExchangeOnlineManagement'
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module" -ForegroundColor Yellow
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
    else {
        Write-Host "Module present: $module" -ForegroundColor Green
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found. Install Azure CLI before continuing.'
}

Write-Host 'Step 01 complete: prerequisites installed.' -ForegroundColor Green
