# Deployment walkthrough (standalone, default profile)

Expected duration: ~25 minutes (≈15 min provisioning for the core; ~25–30 min with all optional
modules). Validated in **swedencentral** (latest: 2026-11-19, see [validation summary](security/validation-summary.md)).
For hub-spoke see [deployment-guide.md](deployment-guide.md) and [hub-integration.md](hub-integration.md).
Which option to choose (public, standalone, hub-spoke, spoke-ready, managed VNet; prompt and hosted agents): [foundry-deployment-options.md](foundry-deployment-options.md) ([PDF](foundry-deployment-options.pdf)).

## 1. Prerequisites

```powershell
az version            # >= 2.70
az bicep version      # >= 0.49
azd version           # >= 1.37
pwsh --version        # >= 7.4
az login; azd auth login
```

Expected: you are **Owner** (or Contributor + Role Based Access Control Administrator) on the
subscription.

## 2. Create the environment

```powershell
git clone <this repo>; cd azure-foundry-private-networking
azd env new contoso-standalone --location swedencentral
# optional: load a sample profile
Get-Content examples/standalone/standalone-bastion.env | ? { $_ -match '^([^#=]+)=(.*)$' } | % { azd env set $Matches[1] $Matches[2] }
```

## 3. Preflight (also runs automatically in `azd provision`)

```powershell
pwsh ./scripts/preflight/preflight.ps1
```

Expected tail:

```text
[4] Model availability and quota (swedencentral)
  [ OK ] Model gpt-5.4-mini 2026-03-17 [DataZoneStandard] available (lifecycle: GenerallyAvailable).
  [ OK ] Quota OpenAI.DataZoneStandard.gpt-5.4-mini : requested 10, available 1000.
...
Preflight passed (1 warning(s)).
```

If it fails nothing is deployed. Typical fixes: register providers, pick another region/model,
lower `MODEL_CAPACITY`, purge a soft-deleted account.

## 4. Preview and provision

```powershell
azd provision --preview     # what-if (nested modules with runtime values are not shown)
azd provision               # ~15 minutes
```

Observed timings (2026-11-17): Foundry account with VNet injection ≈ 5 min, Cosmos DB private
endpoint ≈ 7.5 min, Bastion ≈ 10 min, total 14 min 35 s.

## 5. Validate

```powershell
pwsh ./scripts/validation/Test-Deployment.ps1
```

The script prints PASS / FAIL / INCONCLUSIVE per check and writes `.test-output/validation-*.md`.
It starts the jumpbox if auto-shutdown deallocated it. See
[validation summary](security/validation-summary.md) for the expected results.

## 6. Connect to the jumpbox (interactive)

Azure portal → `vm-jump-xxxxxx` → **Connect** → **Bastion** → Authentication type
**Microsoft Entra ID** → Connect. Sign in with your Entra account (MFA/Conditional Access apply).
No local password is needed.

Native client (Windows device joined/registered to the same tenant):

```powershell
az network bastion rdp -n <BASTION_NAME> -g <rg> --target-resource-id <JUMPBOX_VM_ID> --enable-mfa
```

On the jumpbox:

```powershell
Resolve-DnsName <account>.services.ai.azure.com      # 10.80.1.x
Test-NetConnection <account>.openai.azure.com -Port 443
```

Then open Edge → `https://ai.azure.com` → select the project (`standalone-demo` with the sample
profile, otherwise the default `private-demo`; the endpoint is in `azd env get-value AZURE_AI_PROJECT_ENDPOINT`).

## 7. Troubleshooting

See [troubleshooting.md](troubleshooting.md).

## 8. Teardown

```powershell
pwsh ./scripts/cleanup/Remove-Environment.ps1
```

Wait before reusing the environment name: re-creating an account with the same name right after
the purge can fail privately.
