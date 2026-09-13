BeforeAll {
  $module = Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force -PassThru
}

Describe 'Absent-order cancellation' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid())
    $null = New-Item -ItemType Directory $cache
    $delivery = @{BaseUrl='https://example.invalid';Tenant='SOURCE';DestinationTenant='TARGET';CacheDir=$cache}
    $order = [pscustomobject]@{
      order_number='TEST1';updated_date='2026-09-13T12:00:00';progress='assigned';hold=''
      requests=@([pscustomobject]@{kind='cancel';path='/v1/order/cancel';message_key='cancel';payload_json='{"order_number":"TEST1"}'})
    }
    $script:read = [pscustomobject]@{http=404;data=[pscustomobject]@{detail='Order not found for number: TEST1'}}
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($ReadOnly) { return $script:read }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='canceled'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
  }

  It 'finishes locally with a TTL receipt and no cancellation dispatch or creation proof' {
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.Count | Should -Be 1
    $result[0].kind | Should -Be cancel
    $result[0].state | Should -Be sent
    $result[0].status | Should -Be not_required
    $result[0].http | Should -BeNullOrEmpty
    $result[0].error_code | Should -Be order_not_found
    $receipt = Get-Content (Get-ChildItem $cache -Filter '*.R99.X90.*.json').FullName -Raw | ConvertFrom-Json
    $receipt.not_required_reason | Should -Be order_not_found
    $receipt.creation_check.not_found | Should -BeTrue
    $receipt.creation_check.http | Should -Be 404
    $receipt.http | Should -BeNullOrEmpty
    $receipt.response | Should -BeNullOrEmpty
    $receipt.attempt_count | Should -Be 0
    $receipt.attempted_at | Should -BeNullOrEmpty
    (& $module {param($p) (Get-DeliveryIndex $p).created.Count} $cache) | Should -Be 0
    Initialize-CrossroadsDelivery $cache
    @(Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery).Count | Should -Be 0
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery).Count | Should -Be 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $ReadOnly -and $Path -eq '/v1/order/get' -and $Body.order_number -ceq 'TEST1' -and $Tenant -ceq 'SOURCE' -and $DestinationTenant -ceq 'TARGET'
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $AllowWrite }
  }

  It 'preserves prior cancellation response and attempt evidence' {
    $file = Get-ChildItem $cache -Filter '*.X00.*.json'
    $data = Get-Content $file.FullName -Raw | ConvertFrom-Json -DateKind String
    $data.http=503; $data.response='prior transport failure'; $data.attempt_count=2
    $data.attempted_at='2026-09-12T12:00:00Z'; $data.first_attempt_at='2026-09-12T11:00:00Z'
    & $module {param($p,$d) Write-DeliveryItem $p $d} $file.FullName $data
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $receipt = Get-Content (Get-ChildItem $cache -Filter '*.X90.*.json').FullName -Raw | ConvertFrom-Json -DateKind String
    foreach ($field in @('http','response','attempt_count','attempted_at','first_attempt_at','hash','payload_json')) {
      $receipt.$field | Should -Be $data.$field
    }
    $receipt.status | Should -Be not_required
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $AllowWrite }
  }

  It 'does not finish from <problem>' -ForEach @(
    @{problem='generic404'},@{problem='wrong_order'},@{problem='empty'},@{problem='nonjson'},@{problem='detail_array'},
    @{problem='parse_error'},@{problem='http200'},@{problem='http401'},@{problem='http403'},@{problem='http429'},
    @{problem='http500'},@{problem='timeout'},@{problem='order_present'},@{problem='routing_present'},@{problem='id_present'}
  ) {
    switch ($problem) {
      generic404 { $script:read.data.detail='Not Found' }
      wrong_order { $script:read.data.detail='Order not found for number: OTHER' }
      empty { $script:read.data=$null }
      nonjson { $script:read.data='<html>Not Found</html>' }
      detail_array { $script:read.data.detail=@('Order not found for number: TEST1') }
      parse_error { $script:read | Add-Member parse_error 'invalid JSON' }
      http200 { $script:read.http=200 }
      http401 { $script:read.http=401 }
      http403 { $script:read.http=403 }
      http429 { $script:read.http=429 }
      http500 { $script:read.http=500 }
      timeout { $script:read.http=0 }
      order_present { $script:read.data | Add-Member origin_order ([pscustomobject]@{origin_order_number='TEST1'}) }
      routing_present { $script:read.data | Add-Member routing ([pscustomobject]@{origin_tenant_name='OTHER'}) }
      id_present { $script:read.data | Add-Member _id 'record-1' }
    }
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be waiting_for_create
    @(Get-ChildItem $cache -Filter '*.X00.*.json').Count | Should -Be 1
    @(Get-ChildItem $cache -Filter '*.X90.*.json').Count | Should -Be 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $AllowWrite }
  }

  It 'requires a fresh lookup rather than trusting a saved not-found flag' {
    $file = Get-ChildItem $cache -Filter '*.X00.*.json'
    $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $data | Add-Member creation_check ([pscustomobject]@{not_found=$true;http=404})
    & $module {param($p,$d) Write-DeliveryItem $p $d} $file.FullName $data
    $script:read.http=503
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be waiting_for_create
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $ReadOnly }
  }

  It 'does not borrow another tenant pair or URL' {
    foreach ($field in @('BaseUrl','Tenant','DestinationTenant')) {
      $other=$delivery.Clone(); $other[$field]=if ($field -eq 'BaseUrl') {'https://other.invalid'} else {'OTHER'}
      @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @other).Count | Should -Be 0
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly
    @(Get-ChildItem $cache -Filter '*.X00.*.json').Count | Should -Be 1
  }

  It 'leaves other request kinds held and keeps the live lookup on the cancellation receipt' {
    $order.requests=@([pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"order_number":"TEST1"}'})+$order.requests
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.status | Should -Be @('waiting_for_create','not_required')
    @(Get-ChildItem $cache -Filter '*.R20.X00.*.json').Count | Should -Be 1
    $receipt = Get-Content (Get-ChildItem $cache -Filter '*.R99.X90.*.json').FullName -Raw | ConvertFrom-Json
    $receipt.creation_check.not_found | Should -BeTrue
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $AllowWrite }
  }

  It 'expires normally and sends a later cancellation if the order then exists' {
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    (Get-ChildItem $cache -Filter '*.R99.X90.*.json').LastWriteTime=(Get-Date).AddDays(-30)
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.json').Count | Should -Be 0
    $script:read=[pscustomobject]@{http=200;data=[pscustomobject]@{
      _id='record-1';status='error';origin_order=[pscustomobject]@{origin_order_number='TEST1'}
      routing=[pscustomobject]@{origin_tenant_name='SOURCE';destination_tenant_name='TARGET'}
    }}
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be accepted
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 2 -Exactly -ParameterFilter { $ReadOnly }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $AllowWrite -and $Path -eq '/v1/order/cancel' }
  }
}
