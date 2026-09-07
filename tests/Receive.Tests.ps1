BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
}

Describe 'Receive source data' {
  BeforeEach {
    $config = @{ BillTo = 'ACCOUNT'; BaseUrl = 'https://example.invalid'; Tenant = 'SOURCE'; DestinationTenant = 'TARGET'; CacheDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString())) }
    $script:order = [pscustomobject]@{
      order_number = 'TEST1'; updated_date = '2026-01-01T12:00:00'; progress = 'assigned'; hold = ''
      requests = @([pscustomobject]@{ kind = 'create'; path = '/v1/order/create'; message_key = 'create'; payload_json = '{"order_number":"TEST1"}' })
    }
    Mock Get-CrossroadsTMWData -ModuleName CrossroadsIntegration { $script:order }
  }

  It 'persists requests before advancing and preserves hashes on replay' {
    @(Receive-CrossroadsTMWData @config).Count | Should -Be 0
    Get-CrossroadsDeliveryCursor $config.CacheDir | Should -Be ([datetime]'2026-01-01T12:00:00')
    $before = @(Get-ChildItem $config.CacheDir -Filter '*.X00.*.json' | Get-FileHash).Hash
    $before.Count | Should -Be 1
    $null = Receive-CrossroadsTMWData @config
    @(Get-ChildItem $config.CacheDir -Filter '*.X00.*.json' | Get-FileHash).Hash | Should -Be $before
    Should -Invoke Get-CrossroadsTMWData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $From -eq [datetime]'2026-01-01T11:55:00' -and $null -eq $Through }
  }

  It 'loads the cache index only once while receiving' {
    Mock Get-DeliveryIndex -ModuleName CrossroadsIntegration {
      [pscustomobject]@{legacy=@{}; terminal=@{}; pending_by_hash=@{}; pending=[Collections.Generic.List[object]]::new(); receipts=@{}; old_format=$false}
    }
    $null = Receive-CrossroadsTMWData @config
    Should -Invoke Get-DeliveryIndex -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }

  It 'leaves first-run defaults to SQL and forwards source settings' {
    $null = Receive-CrossroadsTMWData @config -Division DIV -ConnectionString test -SqlFile custom.sql
    Should -Invoke Get-CrossroadsTMWData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $null -eq $From -and $null -eq $Through -and $Division -eq 'DIV' -and $ConnectionString -eq 'test' -and $SqlFile -eq 'custom.sql'
    }
  }

  It 'honors explicit range overrides instead of the cursor' {
    $null = Receive-CrossroadsTMWData @config
    $null = Receive-CrossroadsTMWData @config -From '2025-12-30' -Through '2025-12-31'
    Should -Invoke Get-CrossroadsTMWData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $From -eq [datetime]'2025-12-30' -and $Through -eq [datetime]'2025-12-31' }
  }

  It 'retains pending work and the cursor on an empty source' {
    $null = Receive-CrossroadsTMWData @config
    $before = @(Get-ChildItem $config.CacheDir | Get-FileHash).Hash
    Mock Get-CrossroadsTMWData -ModuleName CrossroadsIntegration {}
    $null = Receive-CrossroadsTMWData @config
    @(Get-ChildItem $config.CacheDir | Get-FileHash).Hash | Should -Be $before
  }

  It 'does not stage or advance after a source failure' {
    Mock Get-CrossroadsTMWData -ModuleName CrossroadsIntegration { throw 'source failed' }
    Mock Add-Delivery -ModuleName CrossroadsIntegration {}
    Mock Set-CrossroadsDeliveryCursor -ModuleName CrossroadsIntegration {}
    { Receive-CrossroadsTMWData @config } | Should -Throw '*source failed*'
    Should -Invoke Add-Delivery -ModuleName CrossroadsIntegration -Times 0
    Should -Invoke Set-CrossroadsDeliveryCursor -ModuleName CrossroadsIntegration -Times 0
  }

  It 'does not advance after a staging failure' {
    Mock Add-Delivery -ModuleName CrossroadsIntegration { throw 'staging failed' }
    Mock Set-CrossroadsDeliveryCursor -ModuleName CrossroadsIntegration {}
    { Receive-CrossroadsTMWData @config } | Should -Throw '*staging failed*'
    Should -Invoke Set-CrossroadsDeliveryCursor -ModuleName CrossroadsIntegration -Times 0
  }

  It 'returns new local holds for the same result table as delivery' {
    $script:order.hold = 'Missing window'
    $script:order.requests = @()
    $result = @(Receive-CrossroadsTMWData @config)
    $result.Count | Should -Be 1
    $result[0].kind | Should -Be 'hold'
    $result[0].state | Should -Be 'rejected'
    $result[0].error | Should -Be 'Missing window'
    @(Receive-CrossroadsTMWData @config).Count | Should -Be 0
  }

  It 'rejects a blank destination before cleanup or source access' {
    $config.BaseUrl = ' '
    Mock Initialize-CrossroadsDelivery -ModuleName CrossroadsIntegration {}
    { Receive-CrossroadsTMWData @config } | Should -Throw
    Should -Invoke Initialize-CrossroadsDelivery -ModuleName CrossroadsIntegration -Times 0
    Should -Invoke Get-CrossroadsTMWData -ModuleName CrossroadsIntegration -Times 0
  }
}

Describe 'Read-only source defaults' {
  It 'makes one SQL call with null dates and does not initialize delivery' {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration {}
    Mock Initialize-CrossroadsDelivery -ModuleName CrossroadsIntegration {}
    Get-CrossroadsTMWData -BillTo ACCOUNT
    Should -Invoke Get-CrossroadsSqlData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $null -eq $Parameters.From -and $null -eq $Parameters.Through }
    Should -Invoke Initialize-CrossroadsDelivery -ModuleName CrossroadsIntegration -Times 0
  }

  It 'rejects an explicitly inverted range without querying SQL' {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration {}
    { Get-CrossroadsTMWData -BillTo ACCOUNT -From '2026-01-02' -Through '2026-01-01' } | Should -Throw '*Through must be after From*'
    Should -Invoke Get-CrossroadsSqlData -ModuleName CrossroadsIntegration -Times 0
  }
}
