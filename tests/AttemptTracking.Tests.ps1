BeforeAll {
  . (Join-Path $PSScriptRoot 'Confirm-TestCreation.ps1')
  $module = Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force -PassThru
}

Describe 'Delivery attempt observability' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid())
    $null = New-Item -ItemType Directory $cache
    $delivery = @{BaseUrl='https://example.invalid';Tenant='SOURCE';DestinationTenant='TARGET';CacheDir=$cache}
    $order = [pscustomobject]@{
      order_number='TEST1';updated_date='2026-09-08T12:00:00';progress='assigned';hold=''
      requests=@([pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"order":{"order_number":"TEST1"}}'})
    }
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=503;data=$null} }
  }

  It 'counts actual dispatches and preserves the first tracked attempt across retry and restart' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $first = Get-ChildItem $cache -Filter '*.R20.*.json' | Get-Content -Raw | ConvertFrom-Json
    $first.attempt_count | Should -Be 1
    $first.attempt_history_complete | Should -BeTrue
    $first.first_attempt_at | Should -Be $first.attempted_at
    Initialize-CrossroadsDelivery $cache
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}} }
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $last = Get-ChildItem $cache -Filter '*.R20.*.json' | Get-Content -Raw | ConvertFrom-Json
    $last.attempt_count | Should -Be 2
    $last.first_attempt_at | Should -Be $first.first_attempt_at
    $last.state | Should -Be sent
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 2 -ParameterFilter { $AllowWrite }
  }

  It 'does not count blocked requests or readbacks as write attempts' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='error';failed_at_step='mapping';origin_order=[pscustomobject]@{origin_order_number='TEST1'};secret='do not persist'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    foreach ($pass in 1,2) { $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery }
    $text = Get-ChildItem $cache -Filter '*.json' | Get-Content -Raw
    $data = $text | ConvertFrom-Json
    $data.attempt_count | Should -Be 0
    $data.attempted_at | Should -BeNullOrEmpty
    $data.creation_check.status | Should -Be error
    $data.creation_check.failed_at_step | Should -Be mapping
    $data.creation_check.origin_matches | Should -BeTrue
    $data.creation_check.confirmed | Should -BeFalse
    $text | Should -Not -Match 'do not persist'
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 0 -ParameterFilter { $AllowWrite }
    @(Get-ChildItem $cache -File).Count | Should -Be 1
  }

  It 'persists unsuccessful readback HTTP <http> without requiring a response object' -ForEach @(@{http=404},@{http=0},@{http=503}) {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=$http;data='not a response object'} }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $data = Get-ChildItem $cache -Filter '*.json' | Get-Content -Raw | ConvertFrom-Json
    $data.creation_check.http | Should -Be $http
    $data.creation_check.confirmed | Should -BeFalse
    $data.attempt_count | Should -Be 0
  }

  It 'does not count a local not-required update transition as a send' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -ParameterFilter { $ReadOnly } {
      [pscustomobject]@{http=404;data=[pscustomobject]@{detail='Order not found for number: TEST1'}}
    }
    $order.requests = @([pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1"}'}) + $order.requests
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}} }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $data = Get-ChildItem $cache -Filter '*.R20.*.json' | Get-Content -Raw | ConvertFrom-Json
    $data.status | Should -Be not_required
    $data.attempt_count | Should -Be 0
    $data.attempted_at | Should -BeNullOrEmpty
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 1 -ParameterFilter { $AllowWrite }
  }

  It 'marks older attempt history unknown instead of inventing a lifetime count' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.R20.*.json'
    $old = Get-Content $file -Raw | ConvertFrom-Json
    foreach ($name in 'attempt_count','first_attempt_at','attempt_history_complete') { $old.PSObject.Properties.Remove($name) }
    $old.attempted_at = '2026-09-08T12:01:00Z'
    $old | ConvertTo-Json -Depth 16 | Set-Content $file
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $data.attempt_count | Should -Be 1
    $data.attempt_history_complete | Should -BeFalse
    $data.first_attempt_at | Should -Not -Be '2026-09-08T12:01:00Z'
  }

  It 'retains an uncertain dispatch when the client throws' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { throw 'transport interrupted' }
    { Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery } | Should -Throw '*transport interrupted*'
    $data = Get-ChildItem $cache -Filter '*.R20.*.json' | Get-Content -Raw | ConvertFrom-Json
    $data.attempt_count | Should -Be 1
    $data.state | Should -Be pending
    $data.http | Should -BeNullOrEmpty
  }

  It 'starts fresh tracking for a changed payload but preserves identical pending work' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    (Get-ChildItem $cache -Filter '*.R20.*.json' | Get-Content -Raw | ConvertFrom-Json).attempt_count | Should -Be 1
    $order.updated_date = '2026-09-08T12:15:00'
    $order.requests[0].payload_json = '{"order":{"order_number":"TEST1"},"note":"changed"}'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $data = Get-ChildItem $cache -Filter '*.R20.*.json' | Get-Content -Raw | ConvertFrom-Json
    $data.attempt_count | Should -Be 0
    $data.first_attempt_at | Should -BeNullOrEmpty
  }

  It 'keeps a rejected create while scoped dependents remain and releases it afterward' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -ParameterFilter { $ReadOnly } {
      [pscustomobject]@{http=404;data=[pscustomobject]@{detail='Order not found for number: TEST1'}}
    }
    $order.requests = @([pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1"}'}) + $order.requests
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=422;data=[pscustomobject]@{detail='mapping missing'}} }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $receipt = Get-ChildItem $cache -Filter '*.R10.X40.*.json'
    $receipt.LastWriteTime = (Get-Date).AddDays(-30)
    Initialize-CrossroadsDelivery $cache
    Test-Path $receipt.FullName | Should -BeTrue
    $order.updated_date = '2026-09-08T12:15:00'
    $order.requests = @()
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    Initialize-CrossroadsDelivery $cache
    Test-Path $receipt.FullName | Should -BeFalse
  }

  It 'does not protect a rejected create from another <field>' -ForEach @(
    @{field='BaseUrl';value='https://other.invalid'}
    @{field='Tenant';value='OTHER'}
    @{field='DestinationTenant';value='OTHER'}
  ) {
    $create = [pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1"}'}
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -ParameterFilter { $ReadOnly } {
      [pscustomobject]@{http=404;data=[pscustomobject]@{detail='Order not found for number: TEST1'}}
    }
    $order.requests = @($create) + $order.requests
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=422;data=[pscustomobject]@{detail='mapping missing'}} }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $other = $delivery.Clone()
    $other[$field] = $value
    $order.requests = @($create)
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @other
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @other
    $receipts = @(Get-ChildItem $cache -Filter '*.R10.X40.*.json')
    $receipts.Count | Should -Be 2
    foreach ($receipt in $receipts) { $receipt.LastWriteTime = (Get-Date).AddDays(-30) }
    Initialize-CrossroadsDelivery $cache
    $remaining = @(Get-ChildItem $cache -Filter '*.R10.X40.*.json' | Get-Content -Raw | ConvertFrom-Json)
    $remaining.Count | Should -Be 1
    $remaining[0].base_url | Should -BeExactly 'https://example.invalid'
    $remaining[0].tenant | Should -BeExactly SOURCE
    $remaining[0].destination_tenant | Should -BeExactly TARGET
  }
}
