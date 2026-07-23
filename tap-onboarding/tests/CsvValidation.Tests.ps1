BeforeAll {
    . "$PSScriptRoot\..\function-code\shared\CsvValidation.ps1"
}

Describe 'CSV validation rules' {
    It 'generates UPN from OtherEmailAddress when UserPrincipalName is blank' {
        $rows = @(
            [pscustomobject]@{
                FirstName = 'John'
                LastName = 'Smith'
                DisplayName = 'John Smith'
                UserPrincipalName = ''
                OtherEmailAddress = 'john.smith@externalcompany.com'
                Department = 'Finance'
                JobTitle = 'Analyst'
                UsageLocation = 'GB'
            }
        )

        $result = Validate-TapCsvRows -Rows $rows -DefaultTenantDomain 'lixongroup.com'

        $result.Summary.ValidRows | Should -Be 1
        $result.ValidRows[0].UserPrincipalName | Should -Be 'john.smith@lixongroup.com'
        $result.ValidRows[0].IsGeneratedUpn | Should -BeTrue
    }

    It 'flags duplicate UPNs in the same CSV' {
        $rows = @(
            [pscustomobject]@{
                FirstName = 'A'
                LastName = 'One'
                DisplayName = 'A One'
                UserPrincipalName = 'same@lixongroup.com'
                OtherEmailAddress = 'a.one@external.com'
                Department = ''
                JobTitle = ''
                UsageLocation = 'GB'
            },
            [pscustomobject]@{
                FirstName = 'B'
                LastName = 'Two'
                DisplayName = 'B Two'
                UserPrincipalName = 'same@lixongroup.com'
                OtherEmailAddress = 'b.two@external.com'
                Department = ''
                JobTitle = ''
                UsageLocation = 'GB'
            }
        )

        $result = Validate-TapCsvRows -Rows $rows -DefaultTenantDomain 'lixongroup.com'

        $result.Summary.InvalidRows | Should -Be 1
        $result.InvalidRows[0].Errors -join '|' | Should -Match 'Duplicate UserPrincipalName within CSV'
    }

    It 'rejects invalid UsageLocation values' {
        $rows = @(
            [pscustomobject]@{
                FirstName = 'Jane'
                LastName = 'Doe'
                DisplayName = 'Jane Doe'
                UserPrincipalName = 'jane.doe@lixongroup.com'
                OtherEmailAddress = 'jane.doe@external.com'
                Department = ''
                JobTitle = ''
                UsageLocation = 'United Kingdom'
            }
        )

        $result = Validate-TapCsvRows -Rows $rows -DefaultTenantDomain 'lixongroup.com'

        $result.Summary.InvalidRows | Should -Be 1
        $result.InvalidRows[0].Errors -join '|' | Should -Match 'UsageLocation must be a 2-letter ISO country code'
    }

    It 'flags existing UPN and OtherEmailAddress from external lookup sets' {
        $rows = @(
            [pscustomobject]@{
                FirstName = 'Nina'
                LastName = 'Ray'
                DisplayName = 'Nina Ray'
                UserPrincipalName = 'nina.ray@lixongroup.com'
                OtherEmailAddress = 'nina.ray@external.com'
                Department = ''
                JobTitle = ''
                UsageLocation = 'GB'
            }
        )

        $existingUpn = @{ 'nina.ray@lixongroup.com' = $true }
        $existingEmail = @{ 'nina.ray@external.com' = $true }

        $result = Validate-TapCsvRows -Rows $rows -DefaultTenantDomain 'lixongroup.com' -ExistingUpnSet $existingUpn -ExistingOtherEmailSet $existingEmail

        $result.Summary.InvalidRows | Should -Be 1
        $allErrors = $result.InvalidRows[0].Errors -join '|'
        $allErrors | Should -Match 'already exists in Entra ID'
        $allErrors | Should -Match 'already has an onboarding record'
    }
}
