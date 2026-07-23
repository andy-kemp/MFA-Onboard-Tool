using namespace System.Net

function New-TapCorsHeaders {
    $origin = if ($env:ADMIN_PORTAL_ORIGIN) { $env:ADMIN_PORTAL_ORIGIN } else { '*' }
    return @{
        'Access-Control-Allow-Origin' = $origin
        'Access-Control-Allow-Methods' = 'GET, POST, OPTIONS'
        'Access-Control-Allow-Headers' = 'Content-Type, Authorization'
    }
}

function Send-TapJsonResponse {
    param(
        [Parameter(Mandatory = $true)]
        [int]$StatusCode,
        [Parameter(Mandatory = $true)]
        [object]$Body,
        [Parameter(Mandatory = $true)]
        [hashtable]$CorsHeaders
    )

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]$StatusCode
        Headers = $CorsHeaders + @{ 'Content-Type' = 'application/json' }
        Body = ($Body | ConvertTo-Json -Depth 20)
    })
}
