# TAP Onboarding Module

This folder contains a standalone Temporary Access Pass onboarding solution for Microsoft Entra ID.

It is intentionally separated from the existing MFA registration application so you can:

- Reuse proven architecture and deployment patterns
- Keep production MFA workflow stable
- Roll out TAP onboarding in controlled pilot waves
- Evolve TAP features independently

This module is designed for an initial pilot of about 200 users and expansion to about 1,100 users using queue-based processing.

## What This Application Is For

This application provides an admin workflow to:

1. Upload and validate onboarding users from CSV
2. Generate missing UPN values from external email and a configured tenant domain
3. Create or match cloud users in Entra ID
4. Add users to a configured default security group
5. Issue Temporary Access Pass credentials
6. Send onboarding email from a shared mailbox using app-only authentication
7. Track onboarding state and outcomes in SharePoint Online
8. Monitor passkey registration completion and reissue TAP where policy allows

## Design Principles

- Separate module, no invasive changes to existing MFA app
- Configuration-driven, no hardcoded tenant-specific ids
- Idempotent and retry-safe processing
- Least privilege Graph permissions
- No persistence of TAP secret or generated password
- Queue-based scaling for larger onboarding populations

## Architecture Overview

- Frontend: Azure Static Web Apps admin portal
- Backend: Azure Functions PowerShell 7.4
- Identity API: Microsoft Graph
- Workflow state: SharePoint list named TAP Onboarding
- Async orchestration: Azure Storage Queue (or Service Bus in future)

See [tap-onboarding/ARCHITECTURE.md](ARCHITECTURE.md) for the full architecture specification.

## Current Implementation Status

### Implemented now (Phase 1)

- Typed configuration loading and validation
- CSV validation engine for TAP schema
- UPN generation and format validation
- Existing UPN check in Entra ID
- Existing onboarding email check in SharePoint records
- Create-or-match Entra user endpoint
- Default group assignment logic
- SharePoint field mapping model
- Unit tests for key rules
- Deployment scaffolding scripts and Bicep

### Planned next phases

- Phase 2: queue orchestration, TAP issuance, HTML email send pipeline
- Phase 3: daily passkey scanner and TAP reissue policy engine
- Phase 4: full admin portal pages and operational actions

## Core Business Flow

1. Admin uploads CSV in portal
2. Backend validates all rows and returns preview
3. Admin approves import explicitly
4. Import job creates one queue message per valid user
5. Worker creates or matches user and assigns group
6. Worker issues TAP and sends onboarding email
7. Worker updates SharePoint status and metadata
8. Daily scanner checks passkey completion and reissue thresholds

## CSV Contract

Supported columns:

- FirstName
- LastName
- DisplayName
- UserPrincipalName
- OtherEmailAddress
- Department
- JobTitle
- UsageLocation

Required columns:

- FirstName
- LastName
- DisplayName
- OtherEmailAddress

Optional columns:

- UserPrincipalName
- Department
- JobTitle
- UsageLocation

UPN generation rule:

- If UserPrincipalName is blank, UPN is generated as:
- Prefix of OtherEmailAddress before @ + @ + DefaultTenantDomain

Example:

- OtherEmailAddress = john.smith@externalcompany.com
- DefaultTenantDomain = lixongroup.com
- Generated UPN = john.smith@lixongroup.com

## Validation Rules

The validator currently enforces:

- Required field presence
- OtherEmailAddress email format
- Supplied UPN format if present
- Generated UPN format
- Duplicate UPN within CSV
- Duplicate OtherEmailAddress within CSV
- Existing UPN in Entra ID
- Existing OtherEmailAddress in SharePoint onboarding list
- Invalid control characters
- DisplayName max length
- UsageLocation format as two-letter ISO code when supplied

Invalid rows are returned with row-level errors. Valid rows remain processable.

## SharePoint Tracking Model

List name:

- TAP Onboarding

State fields are modeled for:

- Identity attributes and immutable UserObjectId
- TAP issuance metadata (no TAP secret)
- Email delivery state
- Passkey registration outcomes
- Retry and manual review signaling
- Import lineage and deterministic processing key

No SharePoint column stores TAP secret or generated password.

## Security Model

### Authentication and authorization

- Admin UI protected by Entra authentication
- Role model target: Reader, Operator, Administrator
- Backend protected by group and role checks for admin operations

### Mail sending authentication

This module supports app-only shared mailbox send using a service principal, with two options:

1. ManagedIdentity mode (recommended)
2. AppRegistration mode (dedicated app/service principal)

Both modes assign Graph Mail.Send application permission and can apply Exchange application access policy mailbox scoping.

### Data protection rules

- Never log TAP secrets
- Never log generated passwords
- Never log access tokens
- Do not persist TAP secret in any store
- Redact sensitive fields from structured errors

## Required Graph Permission Set

Typical application permissions:

- User.Read.All
- User.ReadWrite.All
- GroupMember.ReadWrite.All
- UserAuthenticationMethod.ReadWrite.All
- UserAuthenticationMethod.Read.All
- Mail.Send
- Sites.Selected preferred, Sites.ReadWrite.All only if required

## Shared Mailbox Service Principal Setup

Script:

- [tap-onboarding/03-Configure-Mail-ServicePrincipal.ps1](03-Configure-Mail-ServicePrincipal.ps1)

What this step does:

1. Resolves identity target based on MailAuth.Mode
2. Assigns Mail.Send application role
3. Runs admin consent for app registration mode
4. Optionally creates and configures Exchange application access policy
5. Stores resolved ids back to tap-config.ini

Configuration section:

- [tap-onboarding/tap-config.ini](tap-config.ini) under [MailAuth]

Important options:

- Mode=ManagedIdentity or AppRegistration
- UseApplicationAccessPolicy=true
- PolicyGroupName and PolicyGroupAddress for mailbox scope

## Folder and File Guide

- [tap-onboarding/ARCHITECTURE.md](ARCHITECTURE.md): Full architecture package
- [tap-onboarding/tap-config.ini](tap-config.ini): Tenant configuration
- [tap-onboarding/01-Install-Prerequisites.ps1](01-Install-Prerequisites.ps1): Installs required modules
- [tap-onboarding/03-Configure-Mail-ServicePrincipal.ps1](03-Configure-Mail-ServicePrincipal.ps1): App-only mailbox auth setup
- [tap-onboarding/04-Create-Azure-Resources.ps1](04-Create-Azure-Resources.ps1): Deploys Azure resources
- [tap-onboarding/05-Configure-Function-App.ps1](05-Configure-Function-App.ps1): Sets app settings and deploys code
- [tap-onboarding/infra/main.bicep](infra/main.bicep): Infrastructure template
- [tap-onboarding/function-code](function-code): Function app source
- [tap-onboarding/function-code/shared](function-code/shared): Shared modules
- [tap-onboarding/tests](tests): Pester tests

## Function Endpoints (Current)

Currently implemented:

- POST /api/tap/validate-csv
- POST /api/tap/create-or-match-user

Next endpoints planned:

- StartUserImport
- ProcessUserQueue
- CreateTemporaryAccessPass
- SendOnboardingEmail
- CheckPasskeyRegistration
- DailyOnboardingScanner
- ReissueExpiredTap
- RetryFailedUser
- GetDashboardSummary
- GetOnboardingUsers
- GetImportHistory

## Deployment Runbook

1. Populate tenant values in [tap-onboarding/tap-config.ini](tap-config.ini)
2. Install prerequisites:

```powershell
pwsh ./01-Install-Prerequisites.ps1
```

3. Deploy Azure resources:

```powershell
pwsh ./04-Create-Azure-Resources.ps1
```

4. Configure service principal mailbox auth:

```powershell
pwsh ./03-Configure-Mail-ServicePrincipal.ps1
```

5. Deploy Function App settings and code:

```powershell
pwsh ./05-Configure-Function-App.ps1
```

6. Verify Graph permissions and mailbox scope policy in tenant
7. Validate APIs with test payloads
8. Start with pilot wave and monitor list statuses

## Local Development

1. Prepare local settings from template:

- Copy [tap-onboarding/function-code/local.settings.template.json](function-code/local.settings.template.json) to local.settings.json

2. Run tests:

```powershell
pwsh ./tests/Run-Tests.ps1
```

3. Start Functions host:

```powershell
cd function-code
func start
```

4. Test endpoints locally:

- POST http://localhost:7071/api/tap/validate-csv
- POST http://localhost:7071/api/tap/create-or-match-user

## Pilot Rollout Guidance

For first 200 users:

- Use a dedicated OnboardingWave value
- Run small batches first (for example 25 to 50)
- Verify mailbox delivery, TAP expiry behavior, and passkey completion metrics

For broader 1,100 user rollout:

- Maintain queue-based processing
- Monitor retries and manual-review thresholds
- Track exception report daily for stalled records

## Operational Controls

Target controls:

- MaximumTapAttempts
- MaximumOnboardingDays
- RequireApprovalAfterAttempt
- DisableAutomaticReissue

Defaults in this module are aligned with initial requirements and can be tuned via config.

## Testing

Unit tests included:

- [tap-onboarding/tests/CsvValidation.Tests.ps1](tests/CsvValidation.Tests.ps1)
- [tap-onboarding/tests/TapConfig.Tests.ps1](tests/TapConfig.Tests.ps1)

Run all:

```powershell
pwsh ./tests/Run-Tests.ps1
```

## Known Gaps and Roadmap

Not yet implemented in runtime code:

- TAP creation and in-memory secret handling pipeline
- HTML onboarding email rendering and send function
- Timer scanner for passkey completion checks
- Full static web admin pages and manual operations

These are intentionally staged in Phase 2 to Phase 4 and documented in the architecture package.

## Support and Change Control

- Keep tenant-specific values in [tap-onboarding/tap-config.ini](tap-config.ini)
- Avoid direct edits to root MFA module for TAP changes
- Use pull requests for each phase to keep rollout auditable
