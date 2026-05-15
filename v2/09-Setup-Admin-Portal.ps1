# Step 09 - Setup Admin Portal Settings Storage
# Creates the MFASettings Azure Storage Table, seeds it from mfa-config.ini,
# adds new Function App environment variables, and redeploys function code.

$ErrorActionPreference = "Stop"
$configFile = "$PSScriptRoot\mfa-config.ini"

function Get-IniContent {
    param([string]$Path)
    $ini = @{}
    $section = ""
    switch -regex -file $Path {
        "^\[(.+)\]$" {
            $section = $matches[1]
            $ini[$section] = @{}
        }
        "(.+?)\s*=\s*(.*)" {
            $name  = $matches[1]
            $value = $matches[2]
            $ini[$section][$name] = $value
        }
    }
    return $ini
}

function Get-ConfigValue {
    param([string]$Section, [string]$Key)
    if (-not $config.ContainsKey($Section)) { return "" }
    if (-not $config[$Section].ContainsKey($Key)) { return "" }
    return $config[$Section][$Key]
}

function Write-Step {
    param([string]$Text)
    Write-Host "`n$Text" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "       $Text" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [!] $Text" -ForegroundColor DarkYellow
}

# ── Sections and keys that ARE safe to expose in the admin portal ─────────────
# Sensitive identity/infrastructure keys are deliberately excluded.
$seedMap = [ordered]@{
    Branding = @('LogoUrl', 'CompanyName', 'SupportTeam', 'SupportEmail')
    Email    = @('MailboxName', 'NoReplyMailbox', 'MailboxDelegate', 'EmailSubject', 'ReminderSubject')
    Schedule = @('RecurrenceHours')
    OpsGroup = @('OpsGroupName', 'OpsGroupEmail')
}

# Extra Schedule keys not in the INI yet — seeded with sensible defaults
$scheduleDefaults = [ordered]@{
    EscalationAfterDays  = "14"       # Days without MFA before escalation kicks in
    EscalationSchedule   = "Daily"    # Daily | EveryOtherDay | MonWedFri | Weekdays
}

try {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " Step 09 - Setup Admin Portal Storage   " -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # ── 1. Load config ────────────────────────────────────────────
    if (-not (Test-Path $configFile)) {
        throw "Config file not found: $configFile"
    }
    $config = Get-IniContent -Path $configFile

    # Dump detected sections to help diagnose missing-section issues
    Write-Host "  Detected INI sections: $($config.Keys -join ', ')" -ForegroundColor Gray

    $tenantId           = Get-ConfigValue "Tenant"   "TenantId"
    $subscriptionId     = Get-ConfigValue "Tenant"   "SubscriptionId"
    $resourceGroup      = Get-ConfigValue "Azure"    "ResourceGroup"
    $functionAppName    = Get-ConfigValue "Azure"    "FunctionAppName"
    $storageAccountName = Get-ConfigValue "Azure"    "StorageAccountName"
    $opsGroupId         = Get-ConfigValue "OpsGroup" "OpsGroupId"

    foreach ($required in @($tenantId, $subscriptionId, $resourceGroup, $functionAppName, $storageAccountName)) {
        if ([string]::IsNullOrWhiteSpace($required)) {
            throw "One or more required values are missing from mfa-config.ini. Check [Tenant], [Azure], and [OpsGroup] sections."
        }
    }

    Write-Ok "Config loaded"
    Write-Info "Tenant:          $tenantId"
    Write-Info "Subscription:    $subscriptionId"
    Write-Info "Resource Group:  $resourceGroup"
    Write-Info "Function App:    $functionAppName"
    Write-Info "Storage Account: $storageAccountName"

    # ── 2. Ensure Az PowerShell modules ──────────────────────────
    foreach ($mod in @('Az.Accounts', 'Az.Resources', 'Az.Storage', 'Az.Websites')) {
        if (-not (Get-Module -Name $mod -ListAvailable)) {
            Write-Host "Missing module: $mod. Install with: Install-Module $mod -Force" -ForegroundColor Red
            exit 1
        }
        Import-Module $mod -ErrorAction Stop
    }

    # ── 3. Azure login (Az PowerShell — faster than az CLI) ──────
    Write-Step "Connecting to Azure..."

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or $ctx.Tenant.Id -ne $tenantId -or $ctx.Subscription.Id -ne $subscriptionId) {
        Write-Info "Tenant: $tenantId"
        Write-Host "    A browser window will open for sign-in..." -ForegroundColor Cyan
        Connect-AzAccount -Tenant $tenantId -Subscription $subscriptionId -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
    }
    else {
        Write-Info "Reusing existing Azure session"
    }

    Write-Ok "Logged in as: $($ctx.Account.Id)"
    Write-Info "Subscription: $($ctx.Subscription.Name)"

    # ── 4. Fetch storage account key ──────────────────────────────
    Write-Step "Fetching storage account key..."
    $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroup -Name $storageAccountName -ErrorAction Stop)[0].Value
    if (-not $storageKey) { throw "Could not retrieve storage account key. Ensure you have Owner or Contributor on the resource group." }
    Write-Ok "Storage key retrieved"

    # ── 5. Create the MFASettings table via REST ─────────────────
    $tableName    = "MFASettings"
    $tableBaseUrl = "https://$storageAccountName.table.core.windows.net"

    function Get-TableAuthHeaders {
        # Uses SharedKeyLite — StringToSign = Date + "\n" + CanonicalizedResource
        # CanonicalizedResource = /account/resource_path (without query string)
        param([string]$Resource, [string]$ContentType = "application/json")
        $date = (Get-Date).ToUniversalTime().ToString("R")

        # Strip any query string from $Resource for canonicalization
        $resourcePath = $Resource.Split('?')[0]
        $canonicalResource = "/$storageAccountName/$resourcePath"
        $stringToSign = "$date`n$canonicalResource"

        $keyBytes = [Convert]::FromBase64String($storageKey)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $keyBytes
        $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign)))
        return @{
            'x-ms-date'      = $date
            'x-ms-version'   = '2020-04-08'
            'Authorization'  = "SharedKeyLite $storageAccountName`:$signature"
            'Accept'         = 'application/json;odata=nometadata'
            'Content-Type'   = $ContentType
        }
    }

    Write-Step "Creating Storage Table '$tableName'..."
    try {
        $createBody = @{ TableName = $tableName } | ConvertTo-Json -Compress
        $headers    = Get-TableAuthHeaders -Resource 'Tables'
        Invoke-RestMethod -Uri "$tableBaseUrl/Tables" -Method Post -Headers $headers -Body $createBody -ErrorAction Stop | Out-Null
        Write-Ok "Table created: $tableName"
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 409) {
            Write-Ok "Table already exists — skipping creation"
        }
        else {
            throw "Failed to create table: $_"
        }
    }

    # ── 6. Helper: upsert one entity ──────────────────────────────
    function Set-TableEntity {
        param([string]$PartitionKey, [string]$RowKey, [string]$SettingValue)
        $resource = "$tableName(PartitionKey='$PartitionKey',RowKey='$RowKey')"
        $entity = @{
            PartitionKey = $PartitionKey
            RowKey       = $RowKey
            SettingValue = $SettingValue
        } | ConvertTo-Json -Compress
        # PUT without If-Match = "Insert Or Replace Entity" (upsert).
        # If-Match: * would make this "Update Entity" which 404s when the row does not yet exist.
        $h = Get-TableAuthHeaders -Resource $resource
        Invoke-RestMethod -Uri "$tableBaseUrl/$resource" -Method Put -Headers $h -Body $entity -ErrorAction Stop | Out-Null
    }

    function Get-TableEntity {
        param([string]$PartitionKey, [string]$RowKey)
        $resource = "$tableName(PartitionKey='$PartitionKey',RowKey='$RowKey')"
        $h = Get-TableAuthHeaders -Resource $resource
        try {
            return Invoke-RestMethod -Uri "$tableBaseUrl/$resource" -Method Get -Headers $h -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 404) { return $null }
            throw
        }
    }

    # ── 7. Seed settings from INI ─────────────────────────────────
    Write-Step "Seeding settings from mfa-config.ini..."
    $seeded = 0
    $seedSkipped = 0

    foreach ($section in $seedMap.Keys) {
        foreach ($key in $seedMap[$section]) {
            $value = Get-ConfigValue $section $key
            try {
                Set-TableEntity -PartitionKey $section -RowKey $key -SettingValue $value
                Write-Info "$section/$key = $(if ($value) { $value } else { '(empty)' })"
                $seeded++
            }
            catch {
                Write-Warn "Failed to seed $section/$key`: $($_.Exception.Message)"
                $seedSkipped++
            }
        }
    }

    Write-Step "Seeding schedule defaults..."
    foreach ($key in $scheduleDefaults.Keys) {
        $defaultValue = $scheduleDefaults[$key]
        $existing = Get-TableEntity -PartitionKey 'Schedule' -RowKey $key
        if ($existing) {
            Write-Info "Schedule/$key already set to '$($existing.SettingValue)' — skipping"
        }
        else {
            try {
                Set-TableEntity -PartitionKey 'Schedule' -RowKey $key -SettingValue $defaultValue
                Write-Info "Schedule/$key = $defaultValue (default)"
                $seeded++
            }
            catch {
                Write-Warn "Failed to seed Schedule/$key`: $($_.Exception.Message)"
                $seedSkipped++
            }
        }
    }

    Write-Ok "Seeded $seeded setting(s), $seedSkipped skipped"

    # ── 8. Update Function App environment variables ─────────────
    Write-Step "Configuring Function App environment variables..."

    $existingApp = Get-AzWebApp -ResourceGroupName $resourceGroup -Name $functionAppName -ErrorAction Stop
    $appSettings = @{}
    foreach ($s in $existingApp.SiteConfig.AppSettings) { $appSettings[$s.Name] = $s.Value }

    $appSettings['STORAGE_ACCOUNT_NAME'] = $storageAccountName
    $appSettings['SETTINGS_TABLE_NAME']  = $tableName
    if (-not $appSettings.ContainsKey('ADMIN_PORTAL_ORIGIN')) {
        $appSettings['ADMIN_PORTAL_ORIGIN'] = ''
    }

    if (-not [string]::IsNullOrWhiteSpace($opsGroupId)) {
        $appSettings['OPS_GROUP_ID'] = $opsGroupId
        Write-Info "OPS_GROUP_ID set to: $opsGroupId"
    }
    else {
        Write-Warn "OpsGroupId not set in mfa-config.ini — admin group check will be skipped by the API."
        Write-Warn "Add OpsGroupId to [OpsGroup] section and re-run this script."
    }

    Set-AzWebApp -ResourceGroupName $resourceGroup -Name $functionAppName -AppSettings $appSettings -ErrorAction Stop | Out-Null
    Write-Ok "Environment variables updated"
    Write-Info "STORAGE_ACCOUNT_NAME = $storageAccountName"
    Write-Info "SETTINGS_TABLE_NAME  = $tableName"

    # ── 9. Grant Managed Identity Storage Table Data Contributor ──
    Write-Step "Checking Managed Identity storage permissions..."

    $principalId = $config["Azure"]["MFAPrincipalId"]
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Write-Warn "MFAPrincipalId not found in mfa-config.ini — skipping RBAC assignment."
        Write-Warn "Ensure the Function App Managed Identity has 'Storage Table Data Contributor'"
        Write-Warn "on the storage account, or re-run after populating MFAPrincipalId."
    }
    else {
        $storageResourceId = (Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName).Id
        $roleName = "Storage Table Data Contributor"
        $existing = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleName -Scope $storageResourceId -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Ok "$roleName already assigned"
        }
        else {
            Write-Warn "Assigning '$roleName' to Managed Identity..."
            try {
                New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleName -Scope $storageResourceId -ErrorAction Stop | Out-Null
                Write-Ok "RBAC role assigned — may take a few minutes to propagate"
            }
            catch {
                Write-Warn "RBAC assignment failed: $($_.Exception.Message)"
                Write-Warn "Assign '$roleName' manually in the Azure Portal."
            }
        }
    }

    # ── 7. Deploy updated function code ───────────────────────────
    Write-Step "Packaging and deploying function code..."

    $functionCodePath = Join-Path $PSScriptRoot "function-code"
    $zipPath = Join-Path $PSScriptRoot "function-deploy.zip"

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    Compress-Archive -Path "$functionCodePath\*" -DestinationPath $zipPath -Force
    Write-Info "Package created: $zipPath"

    try {
        Publish-AzWebApp -ResourceGroupName $resourceGroup -Name $functionAppName -ArchivePath $zipPath -Force -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Function App deployment failed: $($_.Exception.Message)"
    }

    Remove-Item $zipPath -Force
    Write-Ok "Functions deployed"

    # ── 10. Restart and verify ────────────────────────────────────
    Write-Step "Restarting Function App..."
    Restart-AzWebApp -ResourceGroupName $resourceGroup -Name $functionAppName -ErrorAction Stop | Out-Null
    Write-Ok "Function App restarted"

    Write-Host "`nWaiting 30 seconds for deployment to propagate..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30

    $baseUrl = "https://$functionAppName.azurewebsites.net/api"
    Write-Step "Verifying new endpoints..."

    try {
        $testResponse = Invoke-WebRequest -Uri "$baseUrl/admin/settings" -Method Get `
            -ErrorAction SilentlyContinue -MaximumRedirection 0
        # 401 is expected (no Bearer token) — confirms the route is live
        if ($testResponse.StatusCode -in @(200, 401)) {
            Write-Ok "GET /api/admin/settings is responding"
        }
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) {
            Write-Ok "GET /api/admin/settings is responding (401 — auth working correctly)"
        }
        else {
            Write-Warn "Could not verify endpoint — check Function App logs if issues arise"
        }
    }

    # ── 9. Summary ────────────────────────────────────────────────
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host " Step 09 Complete                        " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host " Storage Table : $tableName" -ForegroundColor White
    Write-Host " Storage Acct  : $storageAccountName" -ForegroundColor White
    Write-Host ""
    Write-Host " API Endpoints :" -ForegroundColor White
    Write-Host "   GET  $baseUrl/admin/settings" -ForegroundColor Cyan
    Write-Host "   POST $baseUrl/admin/settings" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " Next step: Run 10-Deploy-Admin-Portal.ps1 to build the admin UI" -ForegroundColor White
    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($opsGroupId)) {
        Write-Host " ACTION REQUIRED:" -ForegroundColor Yellow
        Write-Host "   Add OpsGroupId to [OpsGroup] in mfa-config.ini and re-run this script." -ForegroundColor Yellow
        Write-Host "   Without it the admin API will not enforce group membership checks." -ForegroundColor Yellow
        Write-Host ""
    }
}
catch {
    Write-Host "`n[ERROR] $_" -ForegroundColor Red
    Write-Host "Review the output above and fix any issues before re-running." -ForegroundColor Red
    exit 1
}
