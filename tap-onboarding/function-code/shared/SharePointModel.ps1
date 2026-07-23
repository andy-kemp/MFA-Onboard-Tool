$TapOnboardingStatuses = @(
    'Imported',
    'ValidationFailed',
    'ReadyToCreate',
    'UserCreated',
    'ExistingUser',
    'TAPIssued',
    'AwaitingRegistration',
    'Completed',
    'TAPExpired',
    'TAPReissued',
    'EmailFailed',
    'ProcessingFailed',
    'ManualReviewRequired'
)

function New-TapSharePointFields {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Row,
        [Parameter(Mandatory = $true)]
        [string]$ImportId,
        [Parameter(Mandatory = $true)]
        [string]$ImportFileName,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [string]$OnboardingWave = ''
    )

    if ($TapOnboardingStatuses -notcontains $Status) {
        throw "Invalid status value '$Status'."
    }

    $title = "{0} | {1}" -f $Row.DisplayName, $Row.UserPrincipalName
    $processingKey = ("{0}|{1}" -f $ImportId, $Row.UserPrincipalName).ToLowerInvariant()

    return [ordered]@{
        Title = $title
        UserObjectId = $Row.UserObjectId
        UserPrincipalName = $Row.UserPrincipalName
        FirstName = $Row.FirstName
        LastName = $Row.LastName
        DisplayName = $Row.DisplayName
        OtherEmailAddress = $Row.OtherEmailAddress
        Department = $Row.Department
        JobTitle = $Row.JobTitle
        UsageLocation = $Row.UsageLocation
        OnboardingWave = $OnboardingWave
        Status = $Status
        UserCreatedDate = if ($Row.UserCreatedDate) { $Row.UserCreatedDate } else { $null }
        TAPIssuedDate = $null
        TAPExpiryDate = $null
        TAPAttempt = 0
        TAPMethodId = ''
        PasskeyRegistered = $false
        RegisteredAuthenticationMethods = ''
        RegistrationCompletedDate = $null
        LastCheckedDate = $null
        LastEmailSentDate = $null
        EmailDeliveryStatus = ''
        ErrorCode = ''
        ErrorMessage = ''
        RequiresManualReview = $false
        CreatedByImportId = $ImportId
        ImportFileName = $ImportFileName
        ProcessingKey = $processingKey
        ExcludedFromOnboarding = $false
    }
}
