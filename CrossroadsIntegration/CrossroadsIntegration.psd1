@{
  RootModule = 'CrossroadsIntegration.psm1'
  ModuleVersion = '0.1.0'
  GUID = 'ed56fa3c-d6aa-4ced-b958-12adfac734a0'
  Author = 'Roy Ashbrook'
  CompanyName = 'Community'
  Copyright = '(c) 2026 Roy Ashbrook. MIT License.'
  Description = 'Source adapters and durable request delivery for Crossroads.'
  PowerShellVersion = '7.5'
  CompatiblePSEditions = @('Core')
  RequiredModules = @(
    @{ ModuleName = 'CrossroadsClient'; ModuleVersion = '1.0.3' }
    'Clear-Files'
  )
  FunctionsToExport = @(
    'Get-CrossroadsSqlData'
    'Get-CrossroadsTMWData'
    'Receive-CrossroadsTMWData'
    'Get-CrossroadsDeliverySummary'
    'Initialize-CrossroadsDelivery'
    'Get-CrossroadsDeliveryCursor'
    'Set-CrossroadsDeliveryCursor'
    'Add-CrossroadsDelivery'
    'Send-CrossroadsDelivery'
  )
  CmdletsToExport = @()
  VariablesToExport = @()
  AliasesToExport = @()
  FileList = @(
    'CrossroadsIntegration.psd1'
    'CrossroadsIntegration.psm1'
    'Delivery.ps1'
    'Adapters/TMW/TMW.ps1'
    'Adapters/TMW/Get-Source.sql'
    'Adapters/TMW/Get-Requests.sql'
    'README.md'
    'LICENSE'
  )
  PrivateData = @{
    PSData = @{
      Tags = @('Crossroads', 'Gravitate', 'TMW', 'Integration', 'PSEdition_Core')
      LicenseUri = 'https://github.com/royashbrook/crossroads-integration/blob/main/LICENSE'
      ProjectUri = 'https://github.com/royashbrook/crossroads-integration'
      ReleaseNotes = 'Initial release.'
    }
  }
}
