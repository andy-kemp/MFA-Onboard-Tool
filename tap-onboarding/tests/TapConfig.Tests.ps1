BeforeAll {
    . "$PSScriptRoot\..\function-code\shared\TapConfig.ps1"
}

Describe 'TAP configuration validation' {
    It 'throws when required values are missing' {
        $config = [ordered]@{
            TenantId = ''
            DefaultTenantDomain = ''
            DefaultGroupObjectId = ''
            SharePointSiteId = ''
            SharePointListId = ''
            TapLifetimeDays = 7
            MaximumTapAttempts = 2
        }

        { Test-TapConfiguration -Config $config -RequireSharePoint -RequireGroup } | Should -Throw
    }

    It 'accepts a valid configuration' {
        $config = [ordered]@{
            TenantId = '00000000-0000-0000-0000-000000000001'
            DefaultTenantDomain = 'lixongroup.com'
            DefaultGroupObjectId = '00000000-0000-0000-0000-000000000002'
            SharePointSiteId = 'contoso.sharepoint.com,site-guid,web-guid'
            SharePointListId = '00000000-0000-0000-0000-000000000003'
            TapLifetimeDays = 7
            MaximumTapAttempts = 2
        }

        { Test-TapConfiguration -Config $config -RequireSharePoint -RequireGroup } | Should -Not -Throw
    }
}
