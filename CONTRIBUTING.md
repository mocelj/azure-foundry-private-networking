# Contributing

Thanks for your interest! Issues and pull requests are welcome.

- **Questions and bugs:** open an issue with the profile (`examples/**/*.env`), region and the failing step
  (preflight, `azd provision`, `Test-Deployment.ps1`). Remove subscription IDs, tenant IDs, resource names
  and IP addresses from logs first.
- **Security issues:** don't open an issue — see [SECURITY.md](SECURITY.md).
- **Pull requests:** keep changes focused, explain the why, and keep the security baseline: no public data
  planes outside the explicitly labelled `public` profile, Entra ID only (no keys or secrets), least-privilege
  RBAC. Update the related documentation in `docs/`.

Before you open a pull request, run the offline checks (no Azure access needed):

```powershell
az bicep build -f infra/main.bicep
az bicep lint -f infra/main.bicep
Invoke-Pester tests        # Pester 5.5+, PSRule.Rules.Azure for the static security tests
```

The same checks run in CI (`.github/workflows/ci.yml`). Changes to the network design should also be
validated live (`scripts/validation/Test-Deployment.ps1`); mention the profile and result in the pull request.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) and that
you follow the [code of conduct](CODE_OF_CONDUCT.md).
