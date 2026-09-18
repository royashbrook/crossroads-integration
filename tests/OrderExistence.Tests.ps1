BeforeAll {
  $module = Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force -PassThru
}

Describe 'Crossroads existence versus downstream sync' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid())
    $null = New-Item -ItemType Directory $cache
    $delivery = @{BaseUrl='https://example.invalid';Tenant='SOURCE';DestinationTenant='TARGET';CacheDir=$cache}
    $order = [pscustomobject]@{
      order_number='TEST1';updated_date='2026-09-08T12:00:00';progress='complete';hold=''
      requests=@(
        [pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"order":{"order_number":"TEST1"}}'}
        [pscustomobject]@{kind='save_bol';path='/v1/order/save_bol';message_key='bol:B1';payload_json='{"bol_number":"B1"}'}
        [pscustomobject]@{kind='save_drop';path='/v1/order/save_drop';message_key='drop:S1';payload_json='{"site":"S1"}'}
        [pscustomobject]@{kind='status';path='/v1/order/update_status';message_key='status';payload_json='{"progress_status":"complete"}'}
      )
    }
    $script:readback = [pscustomobject]@{
      http=200;data=[pscustomobject]@{
        _id='record-1';status='error';failed_at_step='mapping';destination_order=$null
        origin_order=[pscustomobject]@{origin_order_number='TEST1'}
        routing=[pscustomobject]@{origin_tenant_name='SOURCE';destination_tenant_name='TARGET'}
      }
    }
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($ReadOnly) { return $script:readback }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced';log=[pscustomobject]@{detail=[pscustomobject]@{error='mapping.previous_error'}}}}
    }
  }

  It 'advances acknowledged requests despite aggregate <status>, without claiming destination sync' -ForEach @(@{status='error'},@{status='pending'}) {
    $script:readback.data.status = $status
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.kind | Should -Be @('update','save_bol','save_drop','status')
    $result.state | Should -Be @('sent','sent','sent','sent')
    $proof = Get-ChildItem $cache -Filter '*.R10.X90.*.json' | Get-Content -Raw | ConvertFrom-Json
    $proof.status | Should -Be exists
    $proof.response.destination_synced | Should -BeFalse
    $proof.response.observed_status | Should -Be $status
    $proof.response.destination_order_number | Should -BeNullOrEmpty
    $proof.response.order_id | Should -Be record-1
    $update = Get-ChildItem $cache -Filter '*.R20.X90.*.json' | Get-Content -Raw | ConvertFrom-Json
    $update.creation_check.exists | Should -BeTrue
    $update.creation_check.confirmed | Should -BeFalse
    $update.attempt_count | Should -Be 1
    foreach ($file in Get-ChildItem $cache -Filter '*.json') { $file.LastWriteTime = (Get-Date).AddDays(-30) }
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R10.X90.*.json').Count | Should -Be 0
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 2 -ParameterFilter { $ReadOnly }
  }

  It 'fails closed for <problem>' -ForEach @(
    @{problem='not_found'},@{problem='unauthorized'},@{problem='unavailable'},@{problem='wrong_origin'},
    @{problem='wrong_source'},@{problem='wrong_destination'},@{problem='missing_routing'},
    @{problem='missing_id'},@{problem='wrong_destination_origin'},@{problem='parse_error'},@{problem='synced_wrong_route'}
  ) {
    switch ($problem) {
      not_found { $script:readback.http = 404 }
      unauthorized { $script:readback.http = 403 }
      unavailable { $script:readback.http = 503 }
      wrong_origin { $script:readback.data.origin_order.origin_order_number = 'OTHER' }
      wrong_source { $script:readback.data.routing.origin_tenant_name = 'OTHER' }
      wrong_destination { $script:readback.data.routing.destination_tenant_name = 'OTHER' }
      missing_routing { $script:readback.data.routing = $null }
      missing_id { $script:readback.data._id = '' }
      wrong_destination_origin { $script:readback.data.destination_order = [pscustomobject]@{origin_order_number='OTHER'} }
      parse_error { $script:readback | Add-Member parse_error 'invalid response' }
      synced_wrong_route {
        $script:readback.data.status = 'synced'
        $script:readback.data.routing.destination_tenant_name = 'OTHER'
        $script:readback.data.destination_order = [pscustomobject]@{origin_order_number='TEST1';destination_order_number='D1'}
      }
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be waiting_for_create
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 0 -ParameterFilter { $AllowWrite }
    @(Get-ChildItem $cache -Filter '*.R10.X90.*.json').Count | Should -Be 0
  }

  It 'releases dependent requests when the current update is acknowledged with an application error' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($ReadOnly) { return $script:readback }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='error';message='current request failed'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.status | Should -Be @('accepted','accepted','accepted','accepted')
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 4 -ParameterFilter { $AllowWrite }
  }

  It 'keeps completion blocked when an independent detail is rejected' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($ReadOnly) { return $script:readback }
      if ($Path -eq '/v1/order/save_bol') { return [pscustomobject]@{http=422;data=[pscustomobject]@{detail='current request failed'}} }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.status | Should -Be @('synced','rejected','synced','waiting_for_details')
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 0 -ParameterFilter { $Path -eq '/v1/order/update_status' }
  }

  It 'does not replay an existing rejected update when order existence is established' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($ReadOnly) { return $script:readback }
      [pscustomobject]@{http=422;data=[pscustomobject]@{detail='current request failed'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 1 -ParameterFilter { $AllowWrite }
  }
}
