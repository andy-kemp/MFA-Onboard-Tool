$TapCsvColumns = @(
    'FirstName',
    'LastName',
    'DisplayName',
    'UserPrincipalName',
    'OtherEmailAddress',
    'Department',
    'JobTitle',
    'UsageLocation'
)

$TapCsvRequiredColumns = @(
    'FirstName',
    'LastName',
    'DisplayName',
    'OtherEmailAddress'
)

function Test-EmailAddressFormat {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { return $false }
    return $Email -match '^[^\s@]+@[^\s@]+\.[^\s@]+$'
}

function Test-UserPrincipalNameFormat {
    param([string]$Upn)
    if ([string]::IsNullOrWhiteSpace($Upn)) { return $false }
    return $Upn -match '^[^\s@]+@[^\s@]+\.[^\s@]+$'
}

function Test-InvalidCharacters {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }

    foreach ($ch in $Value.ToCharArray()) {
        if ([char]::IsControl($ch)) {
            return $true
        }
    }

    return $false
}

function New-UpnFromOtherEmail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OtherEmailAddress,
        [Parameter(Mandatory = $true)]
        [string]$DefaultTenantDomain
    )

    $prefix = $OtherEmailAddress.Split('@')[0].Trim()
    return "{0}@{1}" -f $prefix, $DefaultTenantDomain.Trim().ToLowerInvariant()
}

function Convert-TapCsvTextToRows {
    param([Parameter(Mandatory = $true)][string]$CsvText)

    if ([string]::IsNullOrWhiteSpace($CsvText)) {
        throw 'CSV content is empty.'
    }

    $rows = $CsvText | ConvertFrom-Csv
    if ($null -eq $rows -or $rows.Count -eq 0) {
        throw 'CSV content did not contain any data rows.'
    }

    return @($rows)
}

function Test-RequiredColumnsPresent {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $headerNames = $Rows[0].PSObject.Properties.Name
    $missing = @()
    foreach ($required in $TapCsvRequiredColumns) {
        if ($headerNames -notcontains $required) {
            $missing += $required
        }
    }

    return [ordered]@{
        IsValid = ($missing.Count -eq 0)
        MissingColumns = $missing
        HeaderNames = $headerNames
    }
}

function Validate-TapCsvRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,
        [Parameter(Mandatory = $true)]
        [string]$DefaultTenantDomain,
        [hashtable]$ExistingUpnSet,
        [hashtable]$ExistingOtherEmailSet
    )

    $validRows = @()
    $invalidRows = @()

    $seenUpn = @{}
    $seenOtherEmail = @{}

    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $row = $Rows[$i]
        $line = $i + 2

        $firstName = [string]$row.FirstName
        $lastName = [string]$row.LastName
        $displayName = [string]$row.DisplayName
        $inputUpn = [string]$row.UserPrincipalName
        $otherEmail = [string]$row.OtherEmailAddress
        $department = [string]$row.Department
        $jobTitle = [string]$row.JobTitle
        $usageLocation = [string]$row.UsageLocation

        $firstName = $firstName.Trim()
        $lastName = $lastName.Trim()
        $displayName = $displayName.Trim()
        $inputUpn = $inputUpn.Trim()
        $otherEmail = $otherEmail.Trim().ToLowerInvariant()
        $department = $department.Trim()
        $jobTitle = $jobTitle.Trim()
        $usageLocation = $usageLocation.Trim().ToUpperInvariant()

        $errors = @()

        foreach ($field in @('FirstName', 'LastName', 'DisplayName', 'OtherEmailAddress')) {
            if ([string]::IsNullOrWhiteSpace([string]$row.$field)) {
                $errors += "Required field '$field' is missing."
            }
        }

        if (-not (Test-EmailAddressFormat -Email $otherEmail)) {
            $errors += 'OtherEmailAddress is not a valid email address.'
        }

        $finalUpn = $inputUpn
        if ([string]::IsNullOrWhiteSpace($finalUpn)) {
            if (Test-EmailAddressFormat -Email $otherEmail) {
                $finalUpn = New-UpnFromOtherEmail -OtherEmailAddress $otherEmail -DefaultTenantDomain $DefaultTenantDomain
            }
        }

        if (-not (Test-UserPrincipalNameFormat -Upn $finalUpn)) {
            $errors += 'UserPrincipalName is invalid (supplied or generated).'
        }

        if ($seenUpn.ContainsKey($finalUpn.ToLowerInvariant())) {
            $errors += 'Duplicate UserPrincipalName within CSV.'
        }
        else {
            $seenUpn[$finalUpn.ToLowerInvariant()] = $true
        }

        if ($seenOtherEmail.ContainsKey($otherEmail)) {
            $errors += 'Duplicate OtherEmailAddress within CSV.'
        }
        else {
            $seenOtherEmail[$otherEmail] = $true
        }

        if ($ExistingUpnSet -and $ExistingUpnSet.ContainsKey($finalUpn.ToLowerInvariant())) {
            $errors += 'UserPrincipalName already exists in Entra ID.'
        }

        if ($ExistingOtherEmailSet -and $ExistingOtherEmailSet.ContainsKey($otherEmail)) {
            $errors += 'OtherEmailAddress already has an onboarding record.'
        }

        foreach ($value in @($firstName, $lastName, $displayName, $finalUpn, $otherEmail, $department, $jobTitle, $usageLocation)) {
            if (Test-InvalidCharacters -Value $value) {
                $errors += 'Invalid or unsupported characters detected.'
                break
            }
        }

        if ($displayName.Length -gt 256) {
            $errors += 'DisplayName exceeds maximum length (256).'
        }

        if (-not [string]::IsNullOrWhiteSpace($usageLocation) -and $usageLocation -notmatch '^[A-Z]{2}$') {
            $errors += 'UsageLocation must be a 2-letter ISO country code when supplied.'
        }

        $normalized = [ordered]@{
            RowNumber = $line
            FirstName = $firstName
            LastName = $lastName
            DisplayName = $displayName
            UserPrincipalName = $finalUpn.ToLowerInvariant()
            OtherEmailAddress = $otherEmail
            Department = $department
            JobTitle = $jobTitle
            UsageLocation = $usageLocation
            IsGeneratedUpn = [string]::IsNullOrWhiteSpace($inputUpn)
        }

        if ($errors.Count -gt 0) {
            $invalidRows += [ordered]@{
                RowNumber = $line
                UserPrincipalName = $normalized.UserPrincipalName
                OtherEmailAddress = $otherEmail
                Errors = @($errors)
                NormalizedRow = $normalized
            }
            continue
        }

        $validRows += $normalized
    }

    return [ordered]@{
        ValidRows = @($validRows)
        InvalidRows = @($invalidRows)
        Summary = [ordered]@{
            TotalRows = $Rows.Count
            ValidRows = $validRows.Count
            InvalidRows = $invalidRows.Count
        }
    }
}
