function ConvertTo-TapBoolean {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [bool]$DefaultValue = $false
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    $text = $Value.ToString().Trim().ToLowerInvariant()
    if ($text -in @('true', '1', 'yes', 'y')) { return $true }
    if ($text -in @('false', '0', 'no', 'n')) { return $false }
    return $DefaultValue
}

function Get-TapConfiguration {
    if (-not [string]::IsNullOrWhiteSpace($env:TAP_CONFIG_JSON)) {
        $raw = $env:TAP_CONFIG_JSON | ConvertFrom-Json -Depth 20
        return [ordered]@{
            TenantId = $raw.TenantId
            DefaultTenantDomain = $raw.DefaultTenantDomain
            DefaultGroupObjectId = $raw.DefaultGroupObjectId
            AdminGroupObjectId = $raw.AdminGroupObjectId
            SharedMailboxAddress = $raw.SharedMailboxAddress
            SharePointSiteId = $raw.SharePointSiteId
            SharePointListId = $raw.SharePointListId
            TapLifetimeDays = [int]$raw.TapLifetimeDays
            TapIsUsableOnce = [bool]$raw.TapIsUsableOnce
            MaximumTapAttempts = [int]$raw.MaximumTapAttempts
            MaximumOnboardingDays = [int]$raw.MaximumOnboardingDays
            RequireApprovalAfterAttempt = [int]$raw.RequireApprovalAfterAttempt
            DisableAutomaticReissue = [bool]$raw.DisableAutomaticReissue
            ApprovedPasskeyMethodTypes = @($raw.ApprovedPasskeyMethodTypes)
            CompanyDisplayName = $raw.CompanyDisplayName
            SupportEmailAddress = $raw.SupportEmailAddress
            ApplicationLinks = $raw.ApplicationLinks
            EmailTemplatePath = $raw.EmailTemplatePath
        }
    }

    $approvedRaw = if ($env:APPROVED_PASSKEY_METHOD_TYPES) { $env:APPROVED_PASSKEY_METHOD_TYPES } else { 'MicrosoftAuthenticatorPasskey' }
    $approved = $approvedRaw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    return [ordered]@{
        TenantId = $env:TENANT_ID
        DefaultTenantDomain = $env:DEFAULT_TENANT_DOMAIN
        DefaultGroupObjectId = $env:DEFAULT_GROUP_OBJECT_ID
        AdminGroupObjectId = $env:ADMIN_GROUP_OBJECT_ID
        SharedMailboxAddress = $env:SHARED_MAILBOX_ADDRESS
        SharePointSiteId = $env:SHAREPOINT_SITE_ID
        SharePointListId = $env:SHAREPOINT_LIST_ID
        TapLifetimeDays = if ($env:TAP_LIFETIME_DAYS) { [int]$env:TAP_LIFETIME_DAYS } else { 7 }
        TapIsUsableOnce = ConvertTo-TapBoolean -Value $env:TAP_IS_USABLE_ONCE -DefaultValue $true
        MaximumTapAttempts = if ($env:MAXIMUM_TAP_ATTEMPTS) { [int]$env:MAXIMUM_TAP_ATTEMPTS } else { 2 }
        MaximumOnboardingDays = if ($env:MAXIMUM_ONBOARDING_DAYS) { [int]$env:MAXIMUM_ONBOARDING_DAYS } else { 21 }
        RequireApprovalAfterAttempt = if ($env:REQUIRE_APPROVAL_AFTER_ATTEMPT) { [int]$env:REQUIRE_APPROVAL_AFTER_ATTEMPT } else { 2 }
        DisableAutomaticReissue = ConvertTo-TapBoolean -Value $env:DISABLE_AUTOMATIC_REISSUE -DefaultValue $false
        ApprovedPasskeyMethodTypes = $approved
        CompanyDisplayName = $env:COMPANY_DISPLAY_NAME
        SupportEmailAddress = $env:SUPPORT_EMAIL_ADDRESS
        ApplicationLinks = [ordered]@{
            AuthenticatorDownloadUrlIOS = $env:AUTHENTICATOR_DOWNLOAD_URL_IOS
            AuthenticatorDownloadUrlAndroid = $env:AUTHENTICATOR_DOWNLOAD_URL_ANDROID
            MySecurityInfoUrl = $env:MY_SECURITY_INFO_URL
            Microsoft365PortalUrl = $env:MICROSOFT365_PORTAL_URL
            TeamsUrl = $env:TEAMS_URL
            OutlookUrl = $env:OUTLOOK_URL
            SharePointUrl = $env:SHAREPOINT_URL
            PasskeySetupGuideUrl = $env:PASSKEY_SETUP_GUIDE_URL
        }
        EmailTemplatePath = $env:EMAIL_TEMPLATE_PATH
    }
}

function Test-TapConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [switch]$RequireSharePoint,
        [switch]$RequireGroup
    )

    $missing = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($Config.TenantId)) { $missing.Add('TenantId') }
    if ([string]::IsNullOrWhiteSpace($Config.DefaultTenantDomain)) { $missing.Add('DefaultTenantDomain') }

    if ($RequireSharePoint) {
        if ([string]::IsNullOrWhiteSpace($Config.SharePointSiteId)) { $missing.Add('SharePointSiteId') }
        if ([string]::IsNullOrWhiteSpace($Config.SharePointListId)) { $missing.Add('SharePointListId') }
    }

    if ($RequireGroup) {
        if ([string]::IsNullOrWhiteSpace($Config.DefaultGroupObjectId)) { $missing.Add('DefaultGroupObjectId') }
    }

    if ($missing.Count -gt 0) {
        throw "Missing required configuration: $($missing -join ', ')"
    }

    if ($Config.TapLifetimeDays -lt 1 -or $Config.TapLifetimeDays -gt 30) {
        throw 'TapLifetimeDays must be between 1 and 30.'
    }

    if ($Config.MaximumTapAttempts -lt 1) {
        throw 'MaximumTapAttempts must be at least 1.'
    }
}
