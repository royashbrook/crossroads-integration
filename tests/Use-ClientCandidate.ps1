param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('client-candidate-' + [guid]::NewGuid())
$stage = Join-Path $root 'stage'
$modules = Join-Path $root 'modules'
$target = Join-Path $modules 'CrossroadsClient/1.0.6'
$null = New-Item -ItemType Directory $stage, $target -Force
Copy-Item "$Source/*" $stage -Recurse
Update-ModuleManifest (Join-Path $stage 'CrossroadsClient.psd1') -ModuleVersion 1.0.6
Copy-Item "$stage/*" $target -Recurse
$env:PSModulePath = $modules + [IO.Path]::PathSeparator + $env:PSModulePath
if ($env:GITHUB_ENV) { "PSModulePath=$env:PSModulePath" >> $env:GITHUB_ENV }
