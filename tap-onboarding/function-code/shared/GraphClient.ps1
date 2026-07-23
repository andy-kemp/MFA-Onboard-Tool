function Get-ManagedIdentityGraphToken {
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01"
        $tokenResponse = Invoke-RestMethod -Method Get -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } -Uri $tokenUri -ErrorAction Stop
        return $tokenResponse.access_token
    }

    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    return (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com').Token
}

function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$AccessToken,
        [object]$Body,
        [int]$MaxRetries = 5
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++

        try {
            $headers = @{ Authorization = "Bearer $AccessToken" }
            if ($Method -in @('POST', 'PATCH', 'PUT')) {
                $headers['Content-Type'] = 'application/json'
            }

            if ($null -ne $Body) {
                $json = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 20) }
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ErrorAction Stop
            }

            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ErrorAction Stop
        }
        catch {
            $response = $_.Exception.Response
            $statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
            $isRetryable = $statusCode -in @(429, 500, 502, 503, 504)

            if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                throw
            }

            $retryAfterSeconds = 0
            if ($response -and $response.Headers['Retry-After']) {
                [void][int]::TryParse($response.Headers['Retry-After'][0], [ref]$retryAfterSeconds)
            }

            if ($retryAfterSeconds -le 0) {
                $retryAfterSeconds = [Math]::Pow(2, $attempt)
            }

            Start-Sleep -Seconds ([int][Math]::Min(60, $retryAfterSeconds))
        }
    }
}

function Get-UserByUpn {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Upn,
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    $escaped = [uri]::EscapeDataString($Upn)
    $uri = "https://graph.microsoft.com/v1.0/users/$escaped?`$select=id,userPrincipalName,displayName,mail"

    try {
        return Invoke-GraphWithRetry -Method 'GET' -Uri $uri -AccessToken $AccessToken
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }

        throw
    }
}

function New-RandomPassword {
    param([int]$Length = 24)

    if ($Length -lt 16) {
        $Length = 16
    }

    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $digits = '23456789'
    $special = '!@$%*_-+=' 
    $all = ($lower + $upper + $digits + $special).ToCharArray()

    $chars = New-Object System.Collections.Generic.List[char]
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    function Add-RandomChar([string]$source, [System.Collections.Generic.List[char]]$target, $rngObj) {
        $bytes = New-Object byte[] 4
        $rngObj.GetBytes($bytes)
        $index = [BitConverter]::ToUInt32($bytes, 0) % $source.Length
        $target.Add($source[$index])
    }

    Add-RandomChar $lower $chars $rng
    Add-RandomChar $upper $chars $rng
    Add-RandomChar $digits $chars $rng
    Add-RandomChar $special $chars $rng

    while ($chars.Count -lt $Length) {
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $index = [BitConverter]::ToUInt32($bytes, 0) % $all.Length
        $chars.Add($all[$index])
    }

    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $j = [BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
        $tmp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $tmp
    }

    return -join $chars
}

function New-EntraCloudUser {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Row,
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    $initialPassword = New-RandomPassword

    $body = @{
        accountEnabled = $true
        displayName = $Row.DisplayName
        givenName = $Row.FirstName
        surname = $Row.LastName
        userPrincipalName = $Row.UserPrincipalName
        usageLocation = $Row.UsageLocation
        department = $Row.Department
        jobTitle = $Row.JobTitle
        otherMails = @($Row.OtherEmailAddress)
        passwordProfile = @{
            forceChangePasswordNextSignIn = $false
            password = $initialPassword
        }
    }

    $cleanBody = @{}
    foreach ($k in $body.Keys) {
        if ($null -ne $body[$k] -and -not [string]::IsNullOrWhiteSpace([string]$body[$k])) {
            $cleanBody[$k] = $body[$k]
        }
    }

    $uri = 'https://graph.microsoft.com/v1.0/users'
    $created = Invoke-GraphWithRetry -Method 'POST' -Uri $uri -AccessToken $AccessToken -Body $cleanBody

    return [ordered]@{
        User = $created
        GeneratedPassword = $initialPassword
    }
}

function Add-UserToDefaultGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupObjectId,
        [Parameter(Mandatory = $true)]
        [string]$UserObjectId,
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupObjectId/members/`$ref"
    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$UserObjectId" }

    try {
        [void](Invoke-GraphWithRetry -Method 'POST' -Uri $uri -AccessToken $AccessToken -Body $body)
        return 'Added'
    }
    catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 400) {
            return 'AlreadyMember'
        }

        throw
    }
}
