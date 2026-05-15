using namespace System.Net

param($Request, $TriggerMetadata)

# ── CORS headers ──────────────────────────────────────────────────
$origin = if ($env:ADMIN_PORTAL_ORIGIN) { $env:ADMIN_PORTAL_ORIGIN } else { '*' }
$corsHeaders = @{
    'Access-Control-Allow-Origin'  = $origin
    'Access-Control-Allow-Methods' = 'POST, OPTIONS'
    'Access-Control-Allow-Headers' = 'Content-Type, Authorization'
}

# Handle preflight
if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = $corsHeaders
        Body       = ""
    })
    return
}

function Send-JsonResponse {
    param([int]$Code, [object]$Body)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]$Code
        Headers     = $corsHeaders + @{ 'Content-Type' = 'application/json' }
        Body        = $Body | ConvertTo-Json -Depth 10
    })
}

# Keys that cannot be changed via the admin portal (infrastructure/identity values
# that are set at deployment time and would break the system if changed at runtime).
$readOnlyKeys = @(
    'TenantId', 'SubscriptionId', 'ClientId',
    'CertificateThumbprint', 'CertificatePath',
    'MFAGroupId', 'MFAPrincipalId',
    'OpsGroupId'
)

try {
    # ── 1. Validate Bearer token via Graph /me ────────────────────
    $authHeader = $Request.Headers['Authorization']
    if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ')) {
        Send-JsonResponse -Code 401 -Body @{ error = "Unauthorized. A valid Bearer token is required." }
        return
    }
    $bearerToken = $authHeader.Substring(7)

    try {
        $me = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,displayName,userPrincipalName" `
            -Headers @{ Authorization = "Bearer $bearerToken" } -Method Get -ErrorAction Stop
    }
    catch {
        Send-JsonResponse -Code 401 -Body @{ error = "Token validation failed. Ensure you are signed in." }
        return
    }

    Write-Host "save-settings called by: $($me.userPrincipalName)"

    # ── 2. Verify caller is in the Ops/Admin group ────────────────
    $opsGroupId = $env:OPS_GROUP_ID
    if ($opsGroupId) {
        $checkBody = @{ groupIds = @($opsGroupId) } | ConvertTo-Json
        $memberOf = Invoke-RestMethod `
            -Uri "https://graph.microsoft.com/v1.0/users/$($me.id)/checkMemberGroups" `
            -Headers @{ Authorization = "Bearer $bearerToken"; 'Content-Type' = 'application/json' } `
            -Method Post -Body $checkBody -ErrorAction Stop

        if ($memberOf.value -notcontains $opsGroupId) {
            Write-Host "Access denied for $($me.userPrincipalName) - not in OPS group"
            Send-JsonResponse -Code 403 -Body @{ error = "Access denied. Admin group membership required." }
            return
        }
    }

    # ── 3. Parse and validate request body ───────────────────────
    # Expected shape: { "SectionName": { "KeyName": "Value", ... }, ... }
    $body = $Request.Body
    if (-not $body) {
        Send-JsonResponse -Code 400 -Body @{ error = "Request body is empty or not valid JSON." }
        return
    }

    $sections = $body.PSObject.Properties.Name
    if ($sections.Count -eq 0) {
        Send-JsonResponse -Code 400 -Body @{ error = "No settings provided in request body." }
        return
    }

    # ── 4. Get Storage token via Managed Identity ─────────────────
    Connect-AzAccount -Identity -ErrorAction Stop
    $storageToken = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com").Token

    $storageAccount = $env:STORAGE_ACCOUNT_NAME
    $tableName      = if ($env:SETTINGS_TABLE_NAME) { $env:SETTINGS_TABLE_NAME } else { "MFASettings" }
    $tableBaseUrl   = "https://$storageAccount.table.core.windows.net"

    # ── 5. Upsert each key into the Storage Table ─────────────────
    # Uses PUT (InsertOrReplace) — replaces the entity if it exists, inserts if not.
    $upserted = 0
    $skipped  = @()
    $errors   = @()

    foreach ($section in $sections) {
        $sectionObj = $body.$section
        if (-not $sectionObj) { continue }

        foreach ($key in $sectionObj.PSObject.Properties.Name) {
            # Block read-only infrastructure keys
            if ($readOnlyKeys -contains $key) {
                $skipped += "$section/$key"
                Write-Host "Skipping read-only key: $section/$key"
                continue
            }

            $value = $sectionObj.$key
            if ($null -eq $value) { $value = "" }

            # Build the Table Storage entity
            $entity = @{
                PartitionKey  = $section
                RowKey        = $key
                SettingValue  = [string]$value
            } | ConvertTo-Json

            $upsertUrl = "$tableBaseUrl/$tableName(PartitionKey='$section',RowKey='$key')"
            $upsertHeaders = @{
                Authorization  = "Bearer $storageToken"
                'Content-Type' = "application/json"
                Accept         = "application/json;odata=nometadata"
                'x-ms-version' = "2020-04-08"
                'x-ms-date'    = (Get-Date).ToUniversalTime().ToString("R")
            }

            try {
                Invoke-RestMethod -Uri $upsertUrl -Method Put -Headers $upsertHeaders -Body $entity -ErrorAction Stop
                $upserted++
                Write-Host "  Saved: $section/$key"
            }
            catch {
                $errMsg = "$section/$key`: $($_.Exception.Message)"
                Write-Host "  ERROR: $errMsg"
                $errors += $errMsg
            }
        }
    }

    Write-Host "save-settings complete: $upserted saved, $($skipped.Count) skipped, $($errors.Count) errors"

    $responseCode = if ($errors.Count -gt 0 -and $upserted -eq 0) { 500 }
                    elseif ($errors.Count -gt 0) { 207 }
                    else { 200 }

    Send-JsonResponse -Code $responseCode -Body @{
        upserted = $upserted
        skipped  = $skipped
        errors   = $errors
    }
}
catch {
    Write-Host "save-settings ERROR: $_"
    Send-JsonResponse -Code 500 -Body @{ error = "Internal error. Check function logs for details." }
}
