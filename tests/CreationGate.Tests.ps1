BeforeAll {
  . (Join-Path $PSScriptRoot 'Confirm-TestCreation.ps1')
  $module = Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force -PassThru
}

Describe 'Destination creation prerequisite' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid())
    $null = New-Item -ItemType Directory $cache
    $delivery = @{BaseUrl='https://example.invalid';Tenant='SOURCE';DestinationTenant='TARGET';CacheDir=$cache}
    $order = [pscustomobject]@{
      order_number='TEST1';updated_date='2026-09-08T12:00:00';progress='assigned';hold=''
      requests=@([pscustomobject]@{kind='status';path='/v1/order/update_status';message_key='status';payload_json='{"order":{"order_number":"TEST1"},"actual":"2026-09-08T12:00:00Z"}'})
    }
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}} }
  }

  It 'waits without network calls when creation has no proof' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    foreach ($pass in 1,2) {
      $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
      $result.Count | Should -Be 1
      $result[0].status | Should -Be waiting_for_create
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly
    Should -Invoke Get-CrossroadsToken -ModuleName CrossroadsIntegration -Times 0 -Exactly
    @(Get-ChildItem $cache -Filter '*.X00.*.json').Count | Should -Be 1
  }

  It 'preserves scoped creation proof through cleanup and later duplicate receipts' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $proof = Get-ChildItem $cache -Filter '*.R10.X90.*.json'
    $proof.LastWriteTime = (Get-Date).AddDays(-30)
    $order.requests = @([pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1","note":"changed"}'}) + $order.requests
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/create') { return [pscustomobject]@{http=422;data=[pscustomobject]@{detail="Duplicate order: An order with number 'TEST1' already exists for this tenant."}} }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
    Initialize-CrossroadsDelivery $cache
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.state | Should -Be @('reconciled','sent')
    Initialize-CrossroadsDelivery $cache
    Test-Path $proof.FullName | Should -BeTrue
    $order.updated_date = '2026-09-08T12:15:00'
    $order.requests = @($order.requests[1])
    $order.requests[0].payload_json = '{"order":{"order_number":"TEST1"},"actual":"2026-09-08T12:15:00Z"}'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].state | Should -Be sent
  }

  It 'does not borrow confirmation from a different <field>' -ForEach @(
    @{field='BaseUrl';value='https://another.invalid'}
    @{field='Tenant';value='OTHER'}
    @{field='DestinationTenant';value='OTHER'}
  ) {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $delivery[$field] = $value
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be waiting_for_create
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly
  }

  It 'keeps empty create acknowledgments unconfirmed' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=200;data=$null} }
    $order.requests = @([pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1"}'}) + $order.requests
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.Count | Should -Be 1
    $result[0].status | Should -Be unconfirmed
    $result[0].state | Should -Be pending
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }

  It 'sends waiting work after a corrected create succeeds' {
    $order.requests = @([pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1","note":"bad"}'}) + $order.requests
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Body -match 'bad') { return [pscustomobject]@{http=422;data=[pscustomobject]@{detail='mapping missing'}} }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].state | Should -Be rejected
    $order.updated_date = '2026-09-08T12:15:00'
    $order.requests[0].payload_json = $order.requests[0].payload_json.Replace('bad','good')
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.kind | Should -Be @('create','status')
    $result.state | Should -Be @('sent','sent')
  }

  It 'retires unsendable pending work using an empty latest snapshot' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $order.updated_date = '2026-09-08T12:15:00'
    $order.requests = @()
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Set-CrossroadsDeliveryCursor -Rows @($order) -CacheDir $cache
    @(Get-ChildItem $cache -Filter '*.X00.*.json').Count | Should -Be 0
    Get-CrossroadsDeliveryCursor $cache | Should -Be ([datetime]$order.updated_date)
  }
}
