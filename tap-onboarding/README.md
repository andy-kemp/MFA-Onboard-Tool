# TAP Onboarding Module (Separate from MFA Module)

This folder is a separate TAP onboarding application that reuses the architecture and operational patterns from the existing MFA onboarding solution, without changing current MFA workflows.

- Language/runtime: PowerShell Azure Functions v4
- Admin frontend target: Azure Static Web Apps
- Workflow state store: SharePoint Online list via Microsoft Graph
- Identity operations: Microsoft Graph API
- Processing model: validate + approve + queue per user

## What is implemented in this bootstrap

This bootstrap delivers Phase 1 working backend components and deployment scaffolding:

- Strongly typed configuration shape and startup validation
- CSV schema parsing and validation with generated UPN support
- Existing-user and existing-onboarding checks
- Entra user create-or-match endpoint
- Default group assignment endpoint logic
- SharePoint field model mapping
- Unit tests for validation and config guards
- Bicep and deployment scripts for isolated TAP resources

## Folder Structure

- `ARCHITECTURE.md`: pre-implementation architecture package
- `tap-config.ini`: environment configuration template (tenant-specific values)
- `infra/main.bicep`: isolated Azure resource deployment
- `01-Install-Prerequisites.ps1`: local prerequisite installer
- `03-Configure-Mail-ServicePrincipal.ps1`: configures Graph Mail.Send app auth and mailbox scoping policy
- `04-Create-Azure-Resources.ps1`: deploy infra from Bicep
- `05-Configure-Function-App.ps1`: apply settings and deploy function code
- `function-code/`: function app code
- `function-code/shared/`: reusable shared modules
- `tests/`: Pester tests

## Reuse Analysis (from existing MFA repo)

### Reused unchanged

- Azure Functions host baseline (`host.json`, `profile.ps1`, `requirements.psd1`)
- Managed identity Graph token pattern
- Deployment script pattern (`01`, `04`, `05` style)
- API CORS/response conventions

### Extended

- CSV validation from single-column UPN to TAP-specific schema and gating
- Existing Graph user lookup logic to support create-or-match decisions
- SharePoint model mapping from simple invite state to richer TAP onboarding state

### New in TAP module

- TAP-specific config model and validation rules
- UPN generation from `OtherEmailAddress` + `DefaultTenantDomain`
- Duplicate checks for UPN and external email in one import
- Status model for TAP onboarding list lifecycle

## Phase-by-Phase Build Plan

### Phase 1 (implemented)

Files created:

- `function-code/shared/TapConfig.ps1`
- `function-code/shared/CsvValidation.ps1`
- `function-code/shared/GraphClient.ps1`
- `function-code/shared/SharePointModel.ps1`
- `function-code/shared/Response.ps1`
- `function-code/ValidateCsv/function.json`
- `function-code/ValidateCsv/run.ps1`
- `function-code/CreateOrMatchUser/function.json`
- `function-code/CreateOrMatchUser/run.ps1`
- `tests/CsvValidation.Tests.ps1`
- `tests/TapConfig.Tests.ps1`
- `tests/Run-Tests.ps1`

What changed:

- Added CSV validation preview endpoint including validation errors per row
- Added create-or-match endpoint that creates cloud users when missing, never logs password, and assigns default group
- Added SharePoint record field mapping helper

### Phase 2 (next)

Planned files:

- `function-code/StartUserImport/*`
- `function-code/ProcessUserQueue/*`
- `function-code/CreateTemporaryAccessPass/*`
- `function-code/SendOnboardingEmail/*`
- `function-code/templates/onboarding-email.html`

What will change:

- Queue-based orchestrated per-user processing
- In-memory TAP handling and immediate email send
- Secure HTML email templating with configurable URLs and support metadata

### Phase 3 (next)

Planned files:

- `function-code/DailyOnboardingScanner/*`
- `function-code/CheckPasskeyRegistration/*`
- `function-code/ReissueExpiredTap/*`

What will change:

- Daily registration scanner
- Approved passkey evaluator
- Automatic TAP reissue and manual review thresholds

### Phase 4 (next)

Planned files:

- `portal-admin/*` (Static Web App UI)
- `function-code/GetDashboardSummary/*`
- `function-code/GetOnboardingUsers/*`
- `function-code/GetImportHistory/*`
- `function-code/RetryFailedUser/*`

What will change:

- Dashboard, import history, user search/filters, manual retry and reissue actions

## Local Development Instructions

1. Install prerequisites:

```powershell
pwsh ./01-Install-Prerequisites.ps1
```

2. Configure local settings:

- Copy `function-code/local.settings.template.json` to `function-code/local.settings.json`
- Populate `TAP_CONFIG_JSON` or set discrete environment variables

3. Run tests:

```powershell
pwsh ./tests/Run-Tests.ps1
```

4. Run Functions locally:

```powershell
cd function-code
func start
```

5. Test endpoints locally:

- `POST http://localhost:7071/api/tap/validate-csv`
- `POST http://localhost:7071/api/tap/create-or-match-user`

## Deployment Instructions

1. Update `tap-config.ini` with tenant values.
2. Deploy infra:

```powershell
pwsh ./04-Create-Azure-Resources.ps1
```

3. Configure shared mailbox send auth using a service principal:

```powershell
pwsh ./03-Configure-Mail-ServicePrincipal.ps1
```

4. Deploy function code + app settings:

```powershell
pwsh ./05-Configure-Function-App.ps1
```

5. Restrict SharePoint site access using `Sites.Selected` where available.

## Shared mailbox app auth notes

- `MailAuth.Mode=ManagedIdentity` is the default and recommended option. It uses the Function App managed identity service principal and avoids secrets.
- `MailAuth.Mode=AppRegistration` creates or reuses a dedicated app registration/service principal.
- Both modes assign Graph application permission `Mail.Send`.
- If `MailAuth.UseApplicationAccessPolicy=true`, the step script creates or reuses a mail-enabled security group, adds the shared mailbox, and creates an Exchange application access policy so the app can only send as scoped mailboxes.

## Important Security Notes

- TAP secret and generated password must never be logged or persisted.
- CSV body should not be fully logged.
- Enforce role-based access in admin APIs (Reader, Operator, Administrator) in Phase 2.
- Restrict Graph and mailbox access to least privilege.
