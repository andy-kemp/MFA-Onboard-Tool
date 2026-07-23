using namespace System.Net

param($Request, $TriggerMetadata)

. "$PSScriptRoot\..\shared\Response.ps1"
. "$PSScriptRoot\..\shared\TapConfig.ps1"
. "$PSScriptRoot\..\shared\CsvValidation.ps1"
. "$PSScriptRoot\..\shared\GraphClient.ps1"

$corsHeaders = New-TapCorsHeaders
if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers = $corsHeaders
        Body = ''
    })
    return
}

function Get-SharePointExistingOtherEmails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteId,
        [Parameter(Mandatory = $true)]
        [string]$ListId,
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    $set = @{}
    $url = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId/items?`$expand=fields(`$select=OtherEmailAddress)&`$top=500"

    while (-not [string]::IsNullOrWhiteSpace($url)) {
        $response = Invoke-GraphWithRetry -Method 'GET' -Uri $url -AccessToken $AccessToken
        foreach ($item in $response.value) {
            $email = [string]$item.fields.OtherEmailAddress
            if (-not [string]::IsNullOrWhiteSpace($email)) {
                $set[$email.Trim().ToLowerInvariant()] = $true
            }
        }

        if ($response.'@odata.nextLink') {
            $url = $response.'@odata.nextLink'
        }
        else {
            $url = $null
        }
    }

    return $set
}

try {
    $config = Get-TapConfiguration
    Test-TapConfiguration -Config $config -RequireSharePoint

    $body = $Request.Body
    $csvText = [string]$body.csv
    $importFileName = [string]$body.importFileName

    if ([string]::IsNullOrWhiteSpace($csvText)) {
        Send-TapJsonResponse -StatusCode 400 -CorsHeaders $corsHeaders -Body @{ error = 'csv is required in request body.' }
        return
    }

    $rows = Convert-TapCsvTextToRows -CsvText $csvText
    $columnsCheck = Test-RequiredColumnsPresent -Rows $rows
    if (-not $columnsCheck.IsValid) {
        Send-TapJsonResponse -StatusCode 400 -CorsHeaders $corsHeaders -Body @{
            error = 'Required CSV columns are missing.'
            missingColumns = $columnsCheck.MissingColumns
            requiredColumns = $TapCsvRequiredColumns
        }
        return
    }

    $accessToken = Get-ManagedIdentityGraphToken

    $existingOtherEmailSet = Get-SharePointExistingOtherEmails -SiteId $config.SharePointSiteId -ListId $config.SharePointListId -AccessToken $accessToken

    $candidateUpns = New-Object System.Collections.Generic.HashSet[string]
    foreach ($row in $rows) {
        $otherEmail = [string]$row.OtherEmailAddress
        $inputUpn = [string]$row.UserPrincipalName
        $resolved = $inputUpn

        if ([string]::IsNullOrWhiteSpace($resolved) -and -not [string]::IsNullOrWhiteSpace($otherEmail)) {
            $resolved = New-UpnFromOtherEmail -OtherEmailAddress $otherEmail.Trim() -DefaultTenantDomain $config.DefaultTenantDomain
        }

        if (Test-UserPrincipalNameFormat -Upn $resolved) {
            [void]$candidateUpns.Add($resolved.Trim().ToLowerInvariant())
        }
    }

    $existingUpnSet = @{}
    foreach ($upn in $candidateUpns) {
        $user = Get-UserByUpn -Upn $upn -AccessToken $accessToken
        if ($null -ne $user) {
            $existingUpnSet[$upn] = $true
        }
    }

    $validation = Validate-TapCsvRows -Rows $rows -DefaultTenantDomain $config.DefaultTenantDomain -ExistingUpnSet $existingUpnSet -ExistingOtherEmailSet $existingOtherEmailSet

    Send-TapJsonResponse -StatusCode 200 -CorsHeaders $corsHeaders -Body @{
        importFileName = $importFileName
        summary = $validation.Summary
        validRows = $validation.ValidRows
        invalidRows = $validation.InvalidRows
        canApproveImport = ($validation.Summary.ValidRows -gt 0)
    }
}
catch {
    Write-Host "ValidateCsv error: $($_.Exception.Message)"
    Send-TapJsonResponse -StatusCode 500 -CorsHeaders $corsHeaders -Body @{
        error = 'Validation failed unexpectedly.'
        detail = $_.Exception.Message
    }
}
