BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
}

Describe 'Public required arguments' {
  BeforeEach {
    Mock Initialize-Delivery -ModuleName CrossroadsIntegration { throw 'Unexpected cache initialization' }
    Mock Get-DeliveryIndex -ModuleName CrossroadsIntegration { throw 'Unexpected cache read' }
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration { throw 'Unexpected SQL access' }
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { throw 'Unexpected authentication' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { throw 'Unexpected HTTP' }
  }

  It '<Command> rejects blank <Field> before IO' -ForEach @(
    @{Command='Get-CrossroadsTMWData';Field='BillTo'}
    @{Command='Receive-CrossroadsTMWData';Field='BillTo'}
    @{Command='Receive-CrossroadsTMWData';Field='Tenant'}
    @{Command='Receive-CrossroadsTMWData';Field='DestinationTenant'}
    @{Command='Add-CrossroadsDelivery';Field='Tenant'}
    @{Command='Add-CrossroadsDelivery';Field='DestinationTenant'}
    @{Command='Send-CrossroadsDelivery';Field='Tenant'}
    @{Command='Send-CrossroadsDelivery';Field='DestinationTenant'}
  ) {
    $config = @{BaseUrl='https://example.invalid';Tenant='SOURCE';DestinationTenant='TARGET';CacheDir=(Join-Path $TestDrive 'cache')}
    if ($Command -eq 'Get-CrossroadsTMWData') { $config = @{BillTo='ACCOUNT'} }
    if ($Command -eq 'Receive-CrossroadsTMWData') { $config.BillTo = 'ACCOUNT' }
    foreach ($value in @($null,'',' ',"`t`r`n")) {
      $config[$Field] = $value
      { & $Command @config } | Should -Throw "*$Field*"
    }
    Should -Invoke Initialize-Delivery -ModuleName CrossroadsIntegration -Times 0
    Should -Invoke Get-DeliveryIndex -ModuleName CrossroadsIntegration -Times 0
    Should -Invoke Get-CrossroadsSqlData -ModuleName CrossroadsIntegration -Times 0
    Should -Invoke Get-CrossroadsToken -ModuleName CrossroadsIntegration -Times 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0
    Test-Path (Join-Path $TestDrive 'cache') | Should -BeFalse
  }
}

Describe 'Optional division' {
  It '<Command> keeps omitted and empty divisions unfiltered' -ForEach @(
    @{Command='Get-CrossroadsTMWData'}
    @{Command='Receive-CrossroadsTMWData'}
  ) {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration {}
    $config = @{BillTo='ACCOUNT'}
    if ($Command -eq 'Receive-CrossroadsTMWData') {
      $config += @{BaseUrl='https://example.invalid';Tenant='SOURCE';DestinationTenant='TARGET';CacheDir=(Join-Path $TestDrive 'cache')}
    }
    & $Command @config
    & $Command @config -Division ''
    & $Command @config -Division $null
    Should -Invoke Get-CrossroadsSqlData -ModuleName CrossroadsIntegration -Times 3 -Exactly -ParameterFilter { $null -eq $Parameters.Division }
  }
}
