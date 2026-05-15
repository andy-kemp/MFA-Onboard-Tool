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

    # ── 2. Azure CLI login ────────────────────────────────────────
    Write-Step "Checking Azure CLI login..."

    # Use a job with a timeout so a stale auth cache can't hang the script
    $accountJob = Start-Job { az account show 2>$null }
    $accountJob | Wait-Job -Timeout 15 | Out-Null
    $accountRaw = if ($accountJob.State -eq 'Completed') { Receive-Job $accountJob } else { $null }
    Remove-Job $accountJob -Force

    $account    = $accountRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
    $needsLogin = (-not $account) -or ($account.tenantId -ne $tenantId)

    if ($needsLogin) {
        Write-Warn "Login required — a browser window will open for you to sign in."
        az login --tenant $tenantId --allow-no-subscriptions 2>$null | Out-Null
        $account = az account show 2>$null | ConvertFrom-Json
        if (-not $account) { throw "az login failed or was cancelled." }
    }

    az account set --subscription $subscriptionId 2>&1 | Out-Null
    Write-Ok "Logged in as: $($account.user.name)"

    # ── Fetch storage account key (used for all table operations) ─
    # --auth-mode login requires the CLI user to have Storage Table Data Contributor.
    # Using the account key works for any subscription Owner/Contributor.
    Write-Step "Fetching storage account key..."
    $storageKey = az storage account keys list `
        --account-name $storageAccountName `
        --resource-group $resourceGroup `
        --query "[0].value" -o tsv 2>$null
    if (-not $storageKey) { throw "Could not retrieve storage account key. Ensure you have Owner or Contributor on the resource group." }
    Write-Ok "Storage key retrieved"

    # ── 3. Create the MFASettings table ──────────────────────────
    $tableName = "MFASettings"
    Write-Step "Creating Storage Table '$tableName'..."

    $tableExists = az storage table exists `
        --account-name $storageAccountName `
        --account-key $storageKey `
        --name $tableName `
        --query "exists" -o tsv 2>$null

    if ($tableExists -eq "true") {
        Write-Ok "Table already exists — skipping creation"
    }
    else {
        az storage table create `
            --account-name $storageAccountName `
            --account-key $storageKey `
            --name $tableName | Out-Null
        Write-Ok "Table created: $tableName"
    }

    # ── 4. Seed settings from INI ─────────────────────────────────
    Write-Step "Seeding settings from mfa-config.ini..."
    $seeded = 0
    $seedSkipped = 0

    foreach ($section in $seedMap.Keys) {
        $iniSection = $section
        foreach ($key in $seedMap[$section]) {
            $value = Get-ConfigValue $iniSection $key

            # az storage entity insert with --if-exists replace acts as upsert
            $result = az storage entity insert `
                --account-name $storageAccountName `
                --account-key $storageKey `
                --table-name $tableName `
                --entity "PartitionKey=$section" "RowKey=$key" "SettingValue=$value" `
                --if-exists replace 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Info "$section/$key = $(if ($value) { $value } else { '(empty)' })"
                $seeded++
            }
            else {
                Write-Warn "Failed to seed $section/$key`: $result"
                $seedSkipped++
            }
        }
    }

    # Seed the extra Schedule defaults (only if the key doesn't already have a value)
    Write-Step "Seeding schedule defaults..."
    foreach ($key in $scheduleDefaults.Keys) {
        $defaultValue = $scheduleDefaults[$key]

        # Check if row already exists
        $existing = az storage entity show `
            --account-name $storageAccountName `
            --account-key $storageKey `
            --table-name $tableName `
            --partition-key "Schedule" `
            --row-key $key 2>$null | ConvertFrom-Json

        if ($existing) {
            Write-Info "Schedule/$key already set to '$($existing.SettingValue)' — skipping"
        }
        else {
            az storage entity insert `
                --account-name $storageAccountName `
                --account-key $storageKey `
                --table-name $tableName `
                --entity "PartitionKey=Schedule" "RowKey=$key" "SettingValue=$defaultValue" `
                --if-exists replace | Out-Null
            Write-Info "Schedule/$key = $defaultValue (default)"
            $seeded++
        }
    }

    Write-Ok "Seeded $seeded setting(s), $seedSkipped skipped"

    # ── 5. Update Function App environment variables ──────────────
    Write-Step "Configuring Function App environment variables..."

    $newSettings = @(
        "STORAGE_ACCOUNT_NAME=$storageAccountName"
        "SETTINGS_TABLE_NAME=$tableName"
        "ADMIN_PORTAL_ORIGIN="   # Empty for now — lock this down once admin portal URL is known
    )

    if (-not [string]::IsNullOrWhiteSpace($opsGroupId)) {
        $newSettings += "OPS_GROUP_ID=$opsGroupId"
        Write-Info "OPS_GROUP_ID set to: $opsGroupId"
    }
    else {
        Write-Warn "OpsGroupId not set in mfa-config.ini — admin group check will be skipped by the API."
        Write-Warn "Add OpsGroupId to [OpsGroup] section and re-run this script."
    }

    az functionapp config appsettings set `
        --resource-group $resourceGroup `
        --name $functionAppName `
        --settings @newSettings `
        2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update Function App settings"
    }

    Write-Ok "Environment variables updated"
    Write-Info "STORAGE_ACCOUNT_NAME = $storageAccountName"
    Write-Info "SETTINGS_TABLE_NAME  = $tableName"

    # ── 6. Grant Managed Identity Storage Table Data Contributor ──
    Write-Step "Checking Managed Identity storage permissions..."

    $principalId = $config["Azure"]["MFAPrincipalId"]
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Write-Warn "MFAPrincipalId not found in mfa-config.ini — skipping RBAC assignment."
        Write-Warn "Ensure the Function App Managed Identity has 'Storage Table Data Contributor'"
        Write-Warn "on the storage account, or re-run after populating MFAPrincipalId."
    }
    else {
        $storageResourceId = az storage account show `
            --name $storageAccountName `
            --resource-group $resourceGroup `
            --query "id" -o tsv

        $roleAssignmentExists = az role assignment list `
            --assignee $principalId `
            --role "Storage Table Data Contributor" `
            --scope $storageResourceId `
            --query "[0].id" -o tsv 2>$null

        if ($roleAssignmentExists) {
            Write-Ok "Storage Table Data Contributor already assigned"
        }
        else {
            Write-Warn "Assigning 'Storage Table Data Contributor' to Managed Identity..."
            az role assignment create `
                --assignee $principalId `
                --role "Storage Table Data Contributor" `
                --scope $storageResourceId | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Ok "RBAC role assigned — may take a few minutes to propagate"
            }
            else {
                Write-Warn "RBAC assignment failed. Assign 'Storage Table Data Contributor' manually in the Azure Portal."
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

    $deployResult = az functionapp deployment source config-zip `
        --resource-group $resourceGroup `
        --name $functionAppName `
        --src $zipPath `
        2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Function App deployment failed: $deployResult"
    }

    Remove-Item $zipPath -Force
    Write-Ok "Functions deployed"

    # ── 8. Restart and verify ─────────────────────────────────────
    Write-Step "Restarting Function App..."
    az functionapp restart --resource-group $resourceGroup --name $functionAppName 2>&1 | Out-Null
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
