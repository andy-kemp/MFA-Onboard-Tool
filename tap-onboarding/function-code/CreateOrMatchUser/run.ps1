using namespace System.Net

param($Request, $TriggerMetadata)

. "$PSScriptRoot\..\shared\Response.ps1"
. "$PSScriptRoot\..\shared\TapConfig.ps1"
. "$PSScriptRoot\..\shared\CsvValidation.ps1"
. "$PSScriptRoot\..\shared\GraphClient.ps1"
. "$PSScriptRoot\..\shared\SharePointModel.ps1"

$corsHeaders = New-TapCorsHeaders
if ($Request.Method -eq 'OPTIONS') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers = $corsHeaders
        Body = ''
    })
    return
}

function Build-RowForValidation {
    param([hashtable]$InputRow)

    return [pscustomobject]@{
        FirstName = $InputRow.FirstName
        LastName = $InputRow.LastName
        DisplayName = $InputRow.DisplayName
        UserPrincipalName = $InputRow.UserPrincipalName
        OtherEmailAddress = $InputRow.OtherEmailAddress
        Department = $InputRow.Department
        JobTitle = $InputRow.JobTitle
        UsageLocation = $InputRow.UsageLocation
    }
}

try {
    $config = Get-TapConfiguration
    Test-TapConfiguration -Config $config -RequireGroup

    $body = $Request.Body
    if ($null -eq $body -or $null -eq $body.row) {
        Send-TapJsonResponse -StatusCode 400 -CorsHeaders $corsHeaders -Body @{ error = 'row is required in request body.' }
        return
    }

    $importId = [string]$body.importId
    $importFileName = [string]$body.importFileName
    if ([string]::IsNullOrWhiteSpace($importId)) {
        $importId = [guid]::NewGuid().ToString()
    }

    $allowExistingUserContinue = [bool]$body.allowExistingUserContinue

    $row = [ordered]@{
        FirstName = [string]$body.row.FirstName
        LastName = [string]$body.row.LastName
        DisplayName = [string]$body.row.DisplayName
        UserPrincipalName = [string]$body.row.UserPrincipalName
        OtherEmailAddress = [string]$body.row.OtherEmailAddress
        Department = [string]$body.row.Department
        JobTitle = [string]$body.row.JobTitle
        UsageLocation = [string]$body.row.UsageLocation
        UserObjectId = [string]$body.row.UserObjectId
    }

    $validationInput = @(Build-RowForValidation -InputRow $row)
    $validation = Validate-TapCsvRows -Rows $validationInput -DefaultTenantDomain $config.DefaultTenantDomain
    if ($validation.InvalidRows.Count -gt 0) {
        Send-TapJsonResponse -StatusCode 400 -CorsHeaders $corsHeaders -Body @{
            error = 'Input row failed validation.'
            validationErrors = $validation.InvalidRows[0].Errors
        }
        return
    }

    $normalizedRow = [ordered]@{}
    foreach ($k in $validation.ValidRows[0].Keys) {
        $normalizedRow[$k] = $validation.ValidRows[0][$k]
    }

    $accessToken = Get-ManagedIdentityGraphToken

    $existingUser = $null
    if (-not [string]::IsNullOrWhiteSpace($row.UserObjectId)) {
        $userUri = "https://graph.microsoft.com/v1.0/users/$($row.UserObjectId)?`$select=id,userPrincipalName,displayName"
        try {
            $existingUser = Invoke-GraphWithRetry -Method 'GET' -Uri $userUri -AccessToken $accessToken
        }
        catch {
            if (-not ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404)) {
                throw
            }
        }
    }

    if ($null -eq $existingUser) {
        $existingUser = Get-UserByUpn -Upn $normalizedRow.UserPrincipalName -AccessToken $accessToken
    }

    $resultStatus = 'UserCreated'
    $groupResult = ''
    $userObjectId = ''

    if ($null -ne $existingUser) {
        $resultStatus = 'ExistingUser'
        $userObjectId = $existingUser.id

        if (-not $allowExistingUserContinue) {
            $spRow = $normalizedRow.Clone()
            $spRow['UserObjectId'] = $userObjectId
            $fields = New-TapSharePointFields -Row $spRow -ImportId $importId -ImportFileName $importFileName -Status 'ExistingUser'

            Send-TapJsonResponse -StatusCode 200 -CorsHeaders $corsHeaders -Body @{
                status = 'ExistingUserSkipped'
                userObjectId = $userObjectId
                userPrincipalName = $existingUser.userPrincipalName
                sharePointFields = $fields
                nextAction = 'AdministratorDecisionRequired'
            }
            return
        }

        $groupResult = Add-UserToDefaultGroup -GroupObjectId $config.DefaultGroupObjectId -UserObjectId $userObjectId -AccessToken $accessToken
    }
    else {
        $created = New-EntraCloudUser -Row $normalizedRow -AccessToken $accessToken
        $userObjectId = $created.User.id

        # Never emit or log the generated password.
        $created.GeneratedPassword = $null

        $groupResult = Add-UserToDefaultGroup -GroupObjectId $config.DefaultGroupObjectId -UserObjectId $userObjectId -AccessToken $accessToken
        $normalizedRow['UserCreatedDate'] = (Get-Date).ToUniversalTime().ToString('o')
    }

    $normalizedRow['UserObjectId'] = $userObjectId
    $fields = New-TapSharePointFields -Row $normalizedRow -ImportId $importId -ImportFileName $importFileName -Status $resultStatus

    Send-TapJsonResponse -StatusCode 200 -CorsHeaders $corsHeaders -Body @{
        status = $resultStatus
        userObjectId = $userObjectId
        userPrincipalName = $normalizedRow.UserPrincipalName
        groupAssignment = $groupResult
        sharePointFields = $fields
    }
}
catch {
    Write-Host "CreateOrMatchUser error: $($_.Exception.Message)"
    Send-TapJsonResponse -StatusCode 500 -CorsHeaders $corsHeaders -Body @{
        error = 'User creation/match failed.'
        detail = $_.Exception.Message
    }
}
