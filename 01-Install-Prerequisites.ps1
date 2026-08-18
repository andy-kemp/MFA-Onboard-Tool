# Step 01 - Prerequisites and Configuration
# Installs required PowerShell modules, gathers configuration, and validates connectivity

$ErrorActionPreference = "Stop"
$configFile = "$PSScriptRoot\mfa-config.ini"

function Get-IniContent {
    param([string]$Path)
    $ini = @{}
    $section = ""
    switch -regex -file $Path {
        "^\[(.+)\]$" {
            $section = $matches[1]
            $ini[$section] = @{}
        }
        "(.+?)\s*=\s*(.*)" {
            $name = $matches[1]
            $value = $matches[2]
            $ini[$section][$name] = $value
        }
    }
    return $ini
}

function Set-IniValue {
    param(
        [string]$Path,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )
    $content = Get-Content $Path
    $inSection = $false
    $found = $false
    $newContent = @()
    
    foreach ($line in $content) {
        if ($line -match "^\[$Section\]") {
            $inSection = $true
            $newContent += $line
        }
        elseif ($line -match "^\[.*\]") {
            if ($inSection -and -not $found) {
                $newContent += "$Key=$Value"
                $found = $true
            }
            $inSection = $false
            $newContent += $line
        }
        elseif ($inSection -and $line -match "^$Key=") {
            $newContent += "$Key=$Value"
            $found = $true
        }
        else {
            $newContent += $line
        }
    }
    
    if ($inSection -and -not $found) {
        $newContent += "$Key=$Value"
    }
    
    $newContent | Set-Content $Path -Force
}

try {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Step 01 - Prerequisites & Configuration" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    $config = Get-IniContent -Path $configFile
    
    # ===========================================
    # Part 1: PowerShell Modules
    # ===========================================
    Write-Host "`n--- Installing PowerShell Modules ---`n" -ForegroundColor Cyan
    
    # Check PowerShell version
    Write-Host "Checking PowerShell version..." -ForegroundColor Yellow
    Write-Host "✓ PowerShell $($PSVersionTable.PSVersion) detected" -ForegroundColor Green
    
    # Check Azure CLI
    Write-Host "`nChecking Azure CLI..." -ForegroundColor Yellow
    try {
        $azVersion = az --version 2>$null | Select-Object -First 1
        if ($azVersion) {
            Write-Host "✓ Azure CLI installed: $($azVersion)" -ForegroundColor Green
        } else {
            throw "Azure CLI not found"
        }
    }
    #
    catch {
        Write-Host "✗ Azure CLI is not installed or not in PATH" -ForegroundColor Red
        Write-Host "`nTo install Azure CLI, run this command in an elevated PowerShell window:" -ForegroundColor Cyan
        Write-Host "`nwinget install -e --id Microsoft.AzureCLI" -ForegroundColor White -BackgroundColor DarkBlue
        Write-Host "`nAlternatively, download from: https://aka.ms/installazurecliwindows" -ForegroundColor Gray
        Write-Host "`nAfter installation, restart this script.`n" -ForegroundColor Yellow
        throw "Azure CLI is required but not installed"
    }
    
    # Required modules
    $modules = @(
        @{Name="PnP.PowerShell"; MinVersion="2.0.0"}
        @{Name="Az.Accounts"; MinVersion="2.0.0"}
        @{Name="Az.Resources"; MinVersion="6.0.0"}
        @{Name="Az.Functions"; MinVersion="4.0.0"}
        @{Name="Az.Storage"; MinVersion="5.0.0"}
        @{Name="Microsoft.Graph.Authentication"; MinVersion="2.0.0"}
        @{Name="Microsoft.Graph.Groups"; MinVersion="2.0.0"}
        @{Name="ExchangeOnlineManagement"; MinVersion="3.0.0"}
    )
    
    Write-Host "`nNote: Cleaning any conflicting module versions..." -ForegroundColor Yellow
    # Remove old Microsoft.Graph modules that might conflict
    Get-Module Microsoft.Graph* | Remove-Module -Force -ErrorAction SilentlyContinue
    
    foreach ($module in $modules) {
        Write-Host "`nChecking module: $($module.Name)..." -ForegroundColor Yellow
        $installed = Get-Module -ListAvailable -Name $module.Name | 
                     Where-Object { $_.Version -ge $module.MinVersion } | 
                     Select-Object -First 1
        
        if ($installed) {
            Write-Host "✓ $($module.Name) v$($installed.Version) already installed" -ForegroundColor Green
        }
        else {
            Write-Host "Installing $($module.Name)..." -ForegroundColor Yellow
            Install-Module -Name $module.Name -MinimumVersion $module.MinVersion -Force -AllowClobber -Scope CurrentUser
            Write-Host "✓ $($module.Name) installed" -ForegroundColor Green
        }
    }
    
    # ===========================================
    # Part 2: Connectivity Tests
    # ===========================================
    Write-Host "`n--- Testing Connectivity ---`n" -ForegroundColor Cyan
    
    # Test Azure connectivity
    Write-Host "Connecting to Azure..." -ForegroundColor Yellow
    Write-Host "Browser authentication will open.`n" -ForegroundColor Gray
    try {
        Connect-AzAccount
        $azContext = Get-AzContext
        
        if ($null -eq $azContext) {
            throw "Failed to connect to Azure"
        }
        
        Write-Host "✓ Connected to Azure as $($azContext.Account.Id)" -ForegroundColor Green
        
        # Handle subscription selection
        $subscriptions = Get-AzSubscription
        if ($subscriptions.Count -gt 1) {
            Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $subscriptions.Count; $i++) {
                $marker = if ($subscriptions[$i].Id -eq $azContext.Subscription.Id) { " (current)" } else { "" }
                Write-Host "  [$i] $($subscriptions[$i].Name)$marker" -ForegroundColor Gray
            }
            Write-Host "`nCurrent: $($azContext.Subscription.Name)" -ForegroundColor Yellow
            $selection = Read-Host "Select subscription number (or press Enter to keep current)"
            
            if (-not [string]::IsNullOrWhiteSpace($selection)) {
                $selectedSub = $subscriptions[$selection]
                Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null
                $azContext = Get-AzContext
                Write-Host "✓ Switched to: $($selectedSub.Name)" -ForegroundColor Green
            }
        }
        
        Write-Host "  Using subscription: $($azContext.Subscription.Name)" -ForegroundColor Gray
    }
    catch {
        throw "Failed to connect to Azure: $($_.Exception.Message)"
    }
    
    # Test Microsoft Graph connectivity
    Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Yellow
    
    # ALWAYS disconnect first to ensure clean connection to correct tenant
    Write-Host "Disconnecting any existing Graph session..." -ForegroundColor Gray
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Ignore errors if not connected
    }
    
    try {
        # Connect to Microsoft Graph with explicit tenant
        $graphTenantId = $azContext.Tenant.Id
        Write-Host "Connecting to Microsoft Graph (Tenant: $graphTenantId)..." -ForegroundColor Yellow
        Connect-MgGraph -TenantId $graphTenantId -Scopes "Group.ReadWrite.All","GroupMember.ReadWrite.All","Sites.FullControl.All" -ErrorAction Stop
        
        $mgContext = Get-MgContext
        Write-Host "✓ Connected to Microsoft Graph" -ForegroundColor Green
        Write-Host "  Account: $($mgContext.Account)" -ForegroundColor Gray
        Write-Host "  Tenant: $($mgContext.TenantId)" -ForegroundColor Gray
        
        # Verify we're connected to the correct tenant
        if ($mgContext.TenantId -ne $azContext.Tenant.Id) {
            Write-Host "⚠ ERROR: Graph connected to wrong tenant!" -ForegroundColor Red
            Write-Host "  Expected: $($azContext.Tenant.Id)" -ForegroundColor Yellow
            Write-Host "  Connected: $($mgContext.TenantId)" -ForegroundColor Yellow
            throw "Graph connection tenant mismatch. Please disconnect and re-run."
        }
    }
    catch {
        throw "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    }
    
    # Validate Tenant ID if set
    if ($config["Tenant"]["TenantId"] -and $config["Tenant"]["TenantId"] -ne "") {
        Write-Host "`nValidating Tenant ID from config..." -ForegroundColor Yellow
        $connectedTenantId = $azContext.Tenant.Id
        $configTenantId = $config["Tenant"]["TenantId"]
        
        # Check if connected to correct tenant
        if ($connectedTenantId -ne $configTenantId -and 
            -not ($azContext.Tenant.Domains -contains $configTenantId)) {
            Write-Host "⚠ ERROR: Tenant ID mismatch!" -ForegroundColor Red
            Write-Host "  Config: $configTenantId" -ForegroundColor Yellow
            Write-Host "  Connected: $connectedTenantId" -ForegroundColor Yellow
            Write-Host "`nYou must connect to the correct tenant." -ForegroundColor Red
            Write-Host "Please disconnect and re-run this script to connect to the correct tenant." -ForegroundColor Yellow
            
            Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            throw "Wrong tenant. Please re-run script to connect to tenant: $configTenantId"
        }
        Write-Host "✓ Tenant ID matches" -ForegroundColor Green
    }
    else {
        Write-Host "⚠ Warning: No Tenant ID configured yet" -ForegroundColor Yellow
        Write-Host "  Connected to: $($azContext.Tenant.Id)" -ForegroundColor Gray
    }
    
    # Save subscription and tenant IDs
    Set-IniValue -Path $configFile -Section "Tenant" -Key "TenantId" -Value $azContext.Tenant.Id
    
    # Handle subscription selection
    Write-Host "`nCurrent subscription: $($azContext.Subscription.Name)" -ForegroundColor Gray
    $changeSubscription = Read-Host "Use this subscription? (Y/N)"
    if ($changeSubscription -eq "N") {
        $subscriptions = Get-AzSubscription
        if ($subscriptions.Count -gt 1) {
            Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $subscriptions.Count; $i++) {
                Write-Host "  [$i] $($subscriptions[$i].Name) - $($subscriptions[$i].Id)" -ForegroundColor Gray
            }
            $selection = Read-Host "Select subscription number"
            $selectedSub = $subscriptions[$selection]
            Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null
            $azContext = Get-AzContext
            Write-Host "✓ Switched to: $($selectedSub.Name)" -ForegroundColor Green
        }
    }
    Set-IniValue -Path $configFile -Section "Tenant" -Key "SubscriptionId" -Value $azContext.Subscription.Id
    
    # ===========================================
    # Part 3: Configuration Gathering
    # ===========================================
    Write-Host "`n--- Deployment Configuration ---`n" -ForegroundColor Cyan
    Write-Host "Please provide the following configuration details." -ForegroundColor Yellow
    Write-Host "Press Enter to accept defaults shown in [brackets].`n" -ForegroundColor Gray
    
    # Tenant Name (for SharePoint URLs)
    $currentTenantName = $config["SharePoint"]["SiteUrl"] -replace '.*://([^.]+)\..*', '$1'
    if ([string]::IsNullOrWhiteSpace($currentTenantName)) {
        $tenantName = Read-Host "Tenant name (e.g., contoso)"
        while ([string]::IsNullOrWhiteSpace($tenantName)) {
            Write-Host "Tenant name cannot be empty" -ForegroundColor Yellow
            $tenantName = Read-Host "Tenant name (e.g., contoso)"
        }
    } else {
        $prompt = Read-Host "Tenant name [$currentTenantName]"
        $tenantName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentTenantName } else { $prompt }
    }
    
    # SharePoint Configuration
    $currentSiteUrl = $config["SharePoint"]["SiteUrl"]
    if ([string]::IsNullOrWhiteSpace($currentSiteUrl)) {
        $siteShort = Read-Host "SharePoint site URL shortname [MFAOps]"
        if ([string]::IsNullOrWhiteSpace($siteShort)) { $siteShort = "MFAOps" }
    } else {
        $currentShort = $currentSiteUrl -replace '.*/sites/([^/]+).*', '$1'
        $prompt = Read-Host "SharePoint site URL shortname [$currentShort]"
        $siteShort = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentShort } else { $prompt }
    }
    
    $siteUrl = "https://$tenantName.sharepoint.com/sites/$siteShort"
    Set-IniValue -Path $configFile -Section "SharePoint" -Key "SiteUrl" -Value $siteUrl
    
    # SharePoint Site Title
    $currentSiteTitle = $config["SharePoint"]["SiteTitle"]
    if ([string]::IsNullOrWhiteSpace($currentSiteTitle)) {
        $prompt = Read-Host "SharePoint site title [MFA Operations]"
        $siteTitle = if ([string]::IsNullOrWhiteSpace($prompt)) { "MFA Operations" } else { $prompt }
    } else {
        $prompt = Read-Host "SharePoint site title [$currentSiteTitle]"
        $siteTitle = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentSiteTitle } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "SharePoint" -Key "SiteTitle" -Value $siteTitle
    
    # SharePoint App Registration Name
    $currentAppRegName = $config["SharePoint"]["AppRegName"]
    if ([string]::IsNullOrWhiteSpace($currentAppRegName)) {
        $prompt = Read-Host "SharePoint App Registration name [SPO-Automation-MFA]"
        $spoAppRegName = if ([string]::IsNullOrWhiteSpace($prompt)) { "SPO-Automation-MFA" } else { $prompt }
    } else {
        $prompt = Read-Host "SharePoint App Registration name [$currentAppRegName]"
        $spoAppRegName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentAppRegName } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "SharePoint" -Key "AppRegName" -Value $spoAppRegName
    
    # SharePoint Site Owner
    Write-Host "`n--- SharePoint Site Owner ---" -ForegroundColor Cyan
    Write-Host "This user will be the site owner (requires SharePoint Admin rights)." -ForegroundColor Gray
    $currentOwner = $config["SharePoint"]["SiteOwner"]
    if ([string]::IsNullOrWhiteSpace($currentOwner)) {
        # Try to suggest current logged in user
        $suggestedOwner = $azContext.Account.Id
        $prompt = Read-Host "Site owner UPN [$suggestedOwner]"
        $siteOwner = if ([string]::IsNullOrWhiteSpace($prompt)) { $suggestedOwner } else { $prompt }
    } else {
        $prompt = Read-Host "Site owner UPN [$currentOwner]"
        $siteOwner = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentOwner } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "SharePoint" -Key "SiteOwner" -Value $siteOwner
    
    # Custom Domains Configuration
    Write-Host "`n--- Custom Domains (Optional) ---" -ForegroundColor Cyan
    Write-Host "Use your own domains instead of Azure defaults (e.g., mfa-register.yourdomain.com)" -ForegroundColor Gray
    
    $useCustom = Read-Host "`nUse custom domains? (Y/N) [N]"
    if ($useCustom -eq "Y") {
        Set-IniValue -Path $configFile -Section "CustomDomains" -Key "UseCustomDomains" -Value "yes"
        
        # Extract domain from site owner email for suggestions
        $domain = $siteOwner -replace '^[^@]+@', ''
        
        Write-Host "`nSuggested domains based on $domain :" -ForegroundColor Gray
        $defaultFunctionDomain = "mfa-register.$domain"
        $defaultPortalDomain = "mfa-portal.$domain"
        
        $prompt = Read-Host "Function App domain [$defaultFunctionDomain]"
        $functionDomain = if ([string]::IsNullOrWhiteSpace($prompt)) { $defaultFunctionDomain } else { $prompt }
        Set-IniValue -Path $configFile -Section "CustomDomains" -Key "FunctionAppDomain" -Value $functionDomain
        
        $prompt = Read-Host "Upload Portal domain [$defaultPortalDomain]"
        $portalDomain = if ([string]::IsNullOrWhiteSpace($prompt)) { $defaultPortalDomain } else { $prompt }
        Set-IniValue -Path $configFile -Section "CustomDomains" -Key "UploadPortalDomain" -Value $portalDomain
        
        # Ask about DNS management
        Write-Host "`n--- DNS Management ---" -ForegroundColor Cyan
        Write-Host "Is your DNS managed in Azure DNS? If yes, CNAME records can be created automatically." -ForegroundColor Gray
        $dnsProvider = Read-Host "`nDNS Provider (Azure/Other) [Other]"
        
        if ($dnsProvider -eq "Azure") {
            Set-IniValue -Path $configFile -Section "CustomDomains" -Key "DNSProvider" -Value "Azure"
            
            # List Azure DNS zones
            Write-Host "`nLooking for Azure DNS zones..." -ForegroundColor Yellow
            $dnsZones = az network dns zone list --query "[].{Name:name, ResourceGroup:resourceGroup, Subscription:id}" -o json | ConvertFrom-Json
            
            if ($dnsZones.Count -eq 0) {
                Write-Host "⚠ No Azure DNS zones found. You'll need to add DNS records manually." -ForegroundColor Yellow
                Set-IniValue -Path $configFile -Section "CustomDomains" -Key "DNSProvider" -Value "Other"
            } else {
                Write-Host "`nAvailable DNS Zones:" -ForegroundColor White
                for ($i = 0; $i -lt $dnsZones.Count; $i++) {
                    $subId = ($dnsZones[$i].Subscription -split '/')[-1]
                    Write-Host "  [$i] $($dnsZones[$i].Name) (RG: $($dnsZones[$i].ResourceGroup), Sub: $subId)" -ForegroundColor Gray
                }
                
                $zoneIndex = Read-Host "`nSelect DNS Zone [0]"
                if ([string]::IsNullOrWhiteSpace($zoneIndex)) { $zoneIndex = 0 }
                
                $selectedZone = $dnsZones[$zoneIndex]
                Set-IniValue -Path $configFile -Section "CustomDomains" -Key "DNSZoneName" -Value $selectedZone.Name
                Set-IniValue -Path $configFile -Section "CustomDomains" -Key "DNSZoneResourceGroup" -Value $selectedZone.ResourceGroup
                Set-IniValue -Path $configFile -Section "CustomDomains" -Key "DNSZoneSubscription" -Value (($selectedZone.Subscription -split '/')[-1])
                
                Write-Host "✓ Azure DNS zone selected: $($selectedZone.Name)" -ForegroundColor Green
                Write-Host "  CNAME records will be created automatically during deployment" -ForegroundColor Gray
            }
        } else {
            Set-IniValue -Path $configFile -Section "CustomDomains" -Key "DNSProvider" -Value "Other"
            Write-Host "✓ External DNS provider - you'll be prompted to add CNAME records manually" -ForegroundColor Green
        }
        
        Write-Host "`n✓ Custom domains configured" -ForegroundColor Green
        Write-Host "  Function App: https://$functionDomain/api/track-mfa-click" -ForegroundColor Gray
        Write-Host "  Portal: https://$portalDomain/" -ForegroundColor Gray
    } else {
        Set-IniValue -Path $configFile -Section "CustomDomains" -Key "UseCustomDomains" -Value "no"
        Set-IniValue -Path $configFile -Section "CustomDomains" -Key "DNSProvider" -Value "None"
        Write-Host "✓ Using Azure default URLs" -ForegroundColor Green
    }
    
    # List Title
    $currentListTitle = $config["SharePoint"]["ListTitle"]
    if ([string]::IsNullOrWhiteSpace($currentListTitle) -or $currentListTitle -eq "MFA Onboarding") {
        $prompt = Read-Host "SharePoint list name [MFA Onboarding]"
        $listTitle = if ([string]::IsNullOrWhiteSpace($prompt)) { "MFA Onboarding" } else { $prompt }
    } else {
        $prompt = Read-Host "SharePoint list name [$currentListTitle]"
        $listTitle = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentListTitle } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "SharePoint" -Key "ListTitle" -Value $listTitle
    
    # Security Group
    Write-Host "`n--- MFA Security Group ---" -ForegroundColor Cyan
    $currentGroupId = $config["Security"]["MFAGroupId"]
    if ([string]::IsNullOrWhiteSpace($currentGroupId)) {
        Write-Host "This group will be used for Conditional Access policy targeting." -ForegroundColor Gray
        $groupChoice = Read-Host "Use existing group or create new? (E=Existing / N=New) [N]"
        if ([string]::IsNullOrWhiteSpace($groupChoice)) { $groupChoice = "N" }
        
        # Use existing Graph connection from Part 2 (already connected with Group.ReadWrite.All scope)
        Write-Host "Using existing Microsoft Graph connection..." -ForegroundColor Gray
        
        if ($groupChoice -eq "E") {
            # Use existing group
            $groupId = Read-Host "Enter Group Object ID"
            while ([string]::IsNullOrWhiteSpace($groupId)) {
                Write-Host "Group Object ID cannot be empty" -ForegroundColor Yellow
                $groupId = Read-Host "Enter Group Object ID"
            }
            
            # Validate group exists
            Write-Host "Validating group..." -ForegroundColor Yellow
            try {
                $result = Get-MgGroup -GroupId $groupId
                Write-Host "✓ Group found: $($result.DisplayName)" -ForegroundColor Green
                Set-IniValue -Path $configFile -Section "Security" -Key "MFAGroupId" -Value $result.Id
                Set-IniValue -Path $configFile -Section "Security" -Key "MFAGroupName" -Value $result.DisplayName
                Set-IniValue -Path $configFile -Section "Security" -Key "MFAGroupMail" -Value $result.Mail
            }
            catch {
                Write-Host "⚠ Could not verify group. Will proceed anyway." -ForegroundColor Yellow
                Set-IniValue -Path $configFile -Section "Security" -Key "MFAGroupId" -Value $groupId
            }
        } else {
            # Create new group - check if name already configured in INI
            $currentGroupName = $config["Security"]["MFAGroupName"]
            if ([string]::IsNullOrWhiteSpace($currentGroupName) -or $currentGroupName -eq "MFA Enabled Users") {
                $prompt = Read-Host "Enter group name [MFA Enabled Users]"
                $groupName = if ([string]::IsNullOrWhiteSpace($prompt)) { "MFA Enabled Users" } else { $prompt }
            } else {
                $prompt = Read-Host "Enter group name [$currentGroupName]"
                $groupName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentGroupName } else { $prompt }
            }
            
            $groupNickname = ($groupName -replace '\s+', '-') -replace '[^a-zA-Z0-9-]', ''
            
            Write-Host "Creating security group..." -ForegroundColor Yellow
            try {
                # Check if group already exists
                $existing = Get-MgGroup -Filter "displayName eq '$groupName'"
                
                if ($existing) {
                    Write-Host "✓ Group already exists: $($existing.DisplayName)" -ForegroundColor Green
                    $group = $existing
                } else {
                    # Create new group using cmdlet
                    $group = New-MgGroup -DisplayName $groupName -MailNickname $groupNickname -MailEnabled:$false -SecurityEnabled:$true -Description "Users who have completed MFA enrollment"
                    Write-Host "✓ Group created: $($group.DisplayName)" -ForegroundColor Green
                }
                
                Set-IniValue -Path $configFile -Section "Security" -Key "MFAGroupId" -Value $group.Id
                Set-IniValue -Path $configFile -Section "Security" -Key "MFAGroupName" -Value $group.DisplayName
                Set-IniValue -Path $configFile -Section "Security" -Key "MFAGroupMail" -Value $group.Mail
                Write-Host "  Object ID: $($group.Id)" -ForegroundColor Gray
            }
            catch {
                Write-Host "ERROR: Failed to create group: $($_.Exception.Message)" -ForegroundColor Red
                throw
            }
        }
    } else {
        Write-Host "✓ Using existing group: $($config['Security']['MFAGroupName'])" -ForegroundColor Green
    }
    
    # Shared Mailbox
    Write-Host "`n--- Shared Mailbox Configuration ---" -ForegroundColor Cyan
    Write-Host "This mailbox will send MFA onboarding notifications to users." -ForegroundColor Gray
    
    # Mailbox Name
    $currentMailboxName = $config["Email"]["MailboxName"]
    if ([string]::IsNullOrWhiteSpace($currentMailboxName)) {
        $prompt = Read-Host "Shared mailbox display name [MFA Registration]"
        $mailboxName = if ([string]::IsNullOrWhiteSpace($prompt)) { "MFA Registration" } else { $prompt }
    } else {
        $prompt = Read-Host "Shared mailbox display name [$currentMailboxName]"
        $mailboxName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentMailboxName } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "Email" -Key "MailboxName" -Value $mailboxName
    
    # Mailbox Email Address
    $currentMailbox = $config["Email"]["NoReplyMailbox"]
    if ([string]::IsNullOrWhiteSpace($currentMailbox)) {
        Write-Host "Enter the email address for the shared mailbox." -ForegroundColor Gray
        $suggestedEmail = "MFA-Registration@$($azContext.Tenant.Domains[0])"
        $prompt = Read-Host "Shared mailbox email [$suggestedEmail]"
        $mailbox = if ([string]::IsNullOrWhiteSpace($prompt)) { $suggestedEmail } else { $prompt }
    } else {
        $prompt = Read-Host "Shared mailbox email [$currentMailbox]"
        $mailbox = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentMailbox } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "Email" -Key "NoReplyMailbox" -Value $mailbox
    
    # Mailbox Delegate (user who can access it)
    Write-Host "`nOptionally grant a user access to this shared mailbox." -ForegroundColor Gray
    $currentDelegate = $config["Email"]["MailboxDelegate"]
    if ([string]::IsNullOrWhiteSpace($currentDelegate)) {
        $delegate = Read-Host "User UPN for mailbox access (leave blank to skip)"
    } else {
        $prompt = Read-Host "User UPN for mailbox access [$currentDelegate] (blank to skip)"
        $delegate = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentDelegate } else { $prompt }
    }
    if (-not [string]::IsNullOrWhiteSpace($delegate)) {
        Set-IniValue -Path $configFile -Section "Email" -Key "MailboxDelegate" -Value $delegate
    }
    
    # Branding Configuration
    Write-Host "`n--- Email Branding (Optional) ---" -ForegroundColor Cyan
    Write-Host "Customize the MFA onboarding emails with your company branding." -ForegroundColor Gray
    
    # Logo URL
    $currentLogo = if ($config.ContainsKey("Branding") -and $config["Branding"].ContainsKey("LogoUrl")) { $config["Branding"]["LogoUrl"] } else { $null }
    if ([string]::IsNullOrWhiteSpace($currentLogo)) {
        Write-Host "`nCompany logo URL (leave blank for no logo)" -ForegroundColor Gray
        $logoUrl = Read-Host "Logo URL"
    } else {
        $prompt = Read-Host "`nLogo URL [$currentLogo] (leave blank to keep current, enter 'none' to remove)"
        if ($prompt -eq 'none') {
            $logoUrl = ""
        } else {
            $logoUrl = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentLogo } else { $prompt }
        }
    }
    Set-IniValue -Path $configFile -Section "Branding" -Key "LogoUrl" -Value $logoUrl
    
    # Company Name
    $currentCompanyName = if ($config.ContainsKey("Branding") -and $config["Branding"].ContainsKey("CompanyName")) { $config["Branding"]["CompanyName"] } else { $null }
    if ([string]::IsNullOrWhiteSpace($currentCompanyName)) {
        $prompt = Read-Host "`nCompany name for emails (leave blank for 'Your Organization')"
        $companyName = if ([string]::IsNullOrWhiteSpace($prompt)) { "Your Organization" } else { $prompt }
    } else {
        $prompt = Read-Host "`nCompany name [$currentCompanyName] (leave blank to keep current)"
        $companyName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentCompanyName } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "Branding" -Key "CompanyName" -Value $companyName
    
    # Support Team Name
    $currentSupportTeam = if ($config.ContainsKey("Branding") -and $config["Branding"].ContainsKey("SupportTeam")) { $config["Branding"]["SupportTeam"] } else { $null }
    if ([string]::IsNullOrWhiteSpace($currentSupportTeam)) {
        $prompt = Read-Host "`nSupport team name (leave blank for 'IT Security Team')"
        $supportTeam = if ([string]::IsNullOrWhiteSpace($prompt)) { "IT Security Team" } else { $prompt }
    } else {
        $prompt = Read-Host "`nSupport team name [$currentSupportTeam] (leave blank to keep current)"
        $supportTeam = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentSupportTeam } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "Branding" -Key "SupportTeam" -Value $supportTeam
    
    # Support Email
    $currentSupportEmail = if ($config.ContainsKey("Branding") -and $config["Branding"].ContainsKey("SupportEmail")) { $config["Branding"]["SupportEmail"] } else { $null }
    $noReplyEmail = $config["Email"]["NoReplyMailbox"]
    if ([string]::IsNullOrWhiteSpace($currentSupportEmail)) {
        $prompt = Read-Host "`nSupport email address (leave blank to use no-reply mailbox: $noReplyEmail)"
        $supportEmail = if ([string]::IsNullOrWhiteSpace($prompt)) { $noReplyEmail } else { $prompt }
    } else {
        $prompt = Read-Host "`nSupport email [$currentSupportEmail] (leave blank to keep current)"
        $supportEmail = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentSupportEmail } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "Branding" -Key "SupportEmail" -Value $supportEmail
    
    # Service Desk Contact
    $currentContact = if ($config.ContainsKey("Branding") -and $config["Branding"].ContainsKey("ServiceDeskContact")) { $config["Branding"]["ServiceDeskContact"] } else { $null }
    if ([string]::IsNullOrWhiteSpace($currentContact)) {
        Write-Host "`nService desk contact info (email or phone, leave blank to hide)" -ForegroundColor Gray
        Write-Host "  Example: support@company.com or +1-555-1234" -ForegroundColor DarkGray
        $contactPrompt = Read-Host "Service desk contact"
        $serviceDeskContact = $contactPrompt
    } else {
        $prompt = Read-Host "`nService desk contact [$currentContact] (blank to hide)"
        $serviceDeskContact = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentContact } else { $prompt }
    }
    if (-not [string]::IsNullOrWhiteSpace($serviceDeskContact)) {
        Set-IniValue -Path $configFile -Section "Branding" -Key "ServiceDeskContact" -Value $serviceDeskContact
    }
    
    # Azure Resources
    Write-Host "`n--- Azure Resource Names ---" -ForegroundColor Cyan
    Write-Host "Configure names for Azure resources (Function App, Storage, etc.)." -ForegroundColor Gray
    
    $currentRG = $config["Azure"]["ResourceGroup"]
    if ([string]::IsNullOrWhiteSpace($currentRG)) {
        $prompt = Read-Host "Resource Group name [rg-mfa-onboarding]"
        $rgName = if ([string]::IsNullOrWhiteSpace($prompt)) { "rg-mfa-onboarding" } else { $prompt }
    } else {
        $prompt = Read-Host "Resource Group name [$currentRG]"
        $rgName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentRG } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "Azure" -Key "ResourceGroup" -Value $rgName
    
    $currentRegion = $config["Azure"]["Region"]
    if ([string]::IsNullOrWhiteSpace($currentRegion)) {
        $prompt = Read-Host "Azure region [uksouth]"
        $region = if ([string]::IsNullOrWhiteSpace($prompt)) { "uksouth" } else { $prompt }
    } else {
        $prompt = Read-Host "Azure region [$currentRegion]"
        $region = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentRegion } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "Azure" -Key "Region" -Value $region
    
    # Upload Portal App Registration Name
    Write-Host "`n--- Upload Portal ---" -ForegroundColor Cyan
    $currentPortalAppRegName = $config["UploadPortal"]["AppRegName"]
    if ([string]::IsNullOrWhiteSpace($currentPortalAppRegName)) {
        $prompt = Read-Host "Upload Portal App Registration name [MFA-Upload-Portal]"
        $portalAppRegName = if ([string]::IsNullOrWhiteSpace($prompt)) { "MFA-Upload-Portal" } else { $prompt }
    } else {
        $prompt = Read-Host "Upload Portal App Registration name [$currentPortalAppRegName]"
        $portalAppRegName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentPortalAppRegName } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "UploadPortal" -Key "AppRegName" -Value $portalAppRegName
    
    # Logic App Name
    $currentLogicApp = $config["LogicApp"]["LogicAppName"]
    if ([string]::IsNullOrWhiteSpace($currentLogicApp)) {
        $prompt = Read-Host "Logic App name [mfa-invite-orchestrator]"
        $logicAppName = if ([string]::IsNullOrWhiteSpace($prompt)) { "mfa-invite-orchestrator" } else { $prompt }
    } else {
        $prompt = Read-Host "Logic App name [$currentLogicApp]"
        $logicAppName = if ([string]::IsNullOrWhiteSpace($prompt)) { $currentLogicApp } else { $prompt }
    }
    Set-IniValue -Path $configFile -Section "LogicApp" -Key "LogicAppName" -Value $logicAppName
    
    # Logic App Recurrence Frequency
    Write-Host "`nLogic App Trigger Schedule:" -ForegroundColor Cyan
    Write-Host "How often should the invitation Logic App check for new users?" -ForegroundColor Gray
    Write-Host "  1 = Every hour (high frequency)" -ForegroundColor Gray
    Write-Host "  2 = Every 2 hours" -ForegroundColor Gray
    Write-Host "  4 = Every 4 hours" -ForegroundColor Gray
    Write-Host "  8 = Every 8 hours" -ForegroundColor Gray
    Write-Host "  12 = Every 12 hours (recommended)" -ForegroundColor Gray
    Write-Host "  24 = Once per day (low frequency)" -ForegroundColor Gray
    
    $currentRecurrence = $config["LogicApp"]["RecurrenceHours"]
    $defaultRecurrence = if ([string]::IsNullOrWhiteSpace($currentRecurrence)) { "12" } else { $currentRecurrence }
    
    do {
        $prompt = Read-Host "Select frequency in hours [$defaultRecurrence]"
        $recurrenceHours = if ([string]::IsNullOrWhiteSpace($prompt)) { $defaultRecurrence } else { $prompt }
        $validFrequencies = @("1", "2", "4", "8", "12", "24")
        if ($recurrenceHours -notin $validFrequencies) {
            Write-Host "Invalid selection. Please choose: 1, 2, 4, 8, 12, or 24" -ForegroundColor Yellow
        }
    } while ($recurrenceHours -notin $validFrequencies)
    
    Set-IniValue -Path $configFile -Section "LogicApp" -Key "RecurrenceHours" -Value $recurrenceHours
    Write-Host "✓ Logic App will check for new users every $recurrenceHours hour(s)" -ForegroundColor Green
    
    # Function App and Storage names will be auto-generated with random suffixes in Step 04
    Write-Host "`nFunction App and Storage Account names will be auto-generated with unique suffixes." -ForegroundColor Gray
    
    Write-Host "`n✓ Configuration saved to mfa-config.ini" -ForegroundColor Green
    
    # Disconnect from services for clean state
    Write-Host "`nDisconnecting from services..." -ForegroundColor Yellow
    try {
        Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "✓ Disconnected from Azure and Graph" -ForegroundColor Green
    } catch {
        # Ignore errors
    }
    
    # Summary
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Configuration Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Subscription: $($azContext.Subscription.Name)" -ForegroundColor Gray
    Write-Host "SharePoint Site: $siteUrl" -ForegroundColor Gray
    Write-Host "  Site Owner: $siteOwner" -ForegroundColor Gray
    Write-Host "  List Name: $listTitle" -ForegroundColor Gray
    Write-Host "Shared Mailbox: $mailbox" -ForegroundColor Gray
    Write-Host "  Display Name: $mailboxName" -ForegroundColor Gray
    if ($delegate) {
        Write-Host "  Delegate Access: $delegate" -ForegroundColor Gray
    }
    Write-Host "Resource Group: $rgName ($region)" -ForegroundColor Gray
    Write-Host "Logic App: $logicAppName" -ForegroundColor Gray
    
    Write-Host "`n✓ Step 01 completed successfully!" -ForegroundColor Green
    Write-Host "Next: Run Deploy-MFA-Solution.ps1 to continue with Step 02`n" -ForegroundColor Cyan
    exit 0
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
