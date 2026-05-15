using namespace System.Net

param($Request, $TriggerMetadata)

# ── CORS headers ──────────────────────────────────────────────────
$origin = if ($env:ADMIN_PORTAL_ORIGIN) { $env:ADMIN_PORTAL_ORIGIN } else { '*' }
$corsHeaders = @{
    'Access-Control-Allow-Origin'  = $origin
    'Access-Control-Allow-Methods' = 'GET, OPTIONS'
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

    Write-Host "get-settings called by: $($me.userPrincipalName)"

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

    # ── 3. Get Storage token via Managed Identity ─────────────────
    Connect-AzAccount -Identity -ErrorAction Stop
    $storageToken = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com").Token

    $storageAccount = $env:STORAGE_ACCOUNT_NAME
    $tableName      = if ($env:SETTINGS_TABLE_NAME) { $env:SETTINGS_TABLE_NAME } else { "MFASettings" }
    $tableBaseUrl   = "https://$storageAccount.table.core.windows.net"

    $storageHeaders = @{
        Authorization  = "Bearer $storageToken"
        Accept         = "application/json;odata=nometadata"
        'x-ms-version' = "2020-04-08"
        'x-ms-date'    = (Get-Date).ToUniversalTime().ToString("R")
    }

    # ── 4. Query all rows from the settings table ─────────────────
    $queryUrl = "$tableBaseUrl/$tableName()?`$select=PartitionKey,RowKey,SettingValue"
    $tableResponse = Invoke-RestMethod -Uri $queryUrl -Headers $storageHeaders -Method Get -ErrorAction Stop

    # ── 5. Group rows by section (PartitionKey) ───────────────────
    $settings = [ordered]@{}
    foreach ($row in $tableResponse.value) {
        if (-not $settings.ContainsKey($row.PartitionKey)) {
            $settings[$row.PartitionKey] = [ordered]@{}
        }
        $settings[$row.PartitionKey][$row.RowKey] = $row.SettingValue
    }

    Write-Host "Returning $($tableResponse.value.Count) settings across $($settings.Keys.Count) section(s)"
    Send-JsonResponse -Code 200 -Body $settings
}
catch {
    Write-Host "get-settings ERROR: $_"
    Send-JsonResponse -Code 500 -Body @{ error = "Internal error. Check function logs for details." }
}
