# CrossroadsIntegration

Source adapters and durable request delivery for the [Gravitate Crossroads Integration API](https://docs.gravitate.energy/docs/crossroads-api/index.html).

```powershell
Install-Module CrossroadsIntegration
Import-Module CrossroadsIntegration
```

SQL or another source builds complete order/request envelopes. The module stages them, suppresses successful replays and retries pending requests through [CrossroadsClient](https://github.com/royashbrook/crossroads-client). A TMW fuel-hauling adapter is included; it is optional and its installation assumptions must be checked before use.

See [usage and operating contract](CrossroadsIntegration/README.md). Credentials, tenant values, cache storage, scheduling and source selection belong to the caller. This is an unofficial community module, not a Gravitate or TMW product.

## Development

```powershell
Install-Module CrossroadsClient,Clear-Files,Pester,PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests -CI
Test-ModuleManifest ./CrossroadsIntegration/CrossroadsIntegration.psd1
```

Tests use synthetic data and mocked HTTP. They do not connect to a database or customer endpoint.

## Releases

A `vX.Y` tag selects major/minor. Patch is the commit count since that tag. Main commits publish after Windows/Linux validation; an existing gallery version is skipped. Only manifest-listed runtime files enter the package.

MIT licensed.
