BeforeAll {
  . (Join-Path $PSScriptRoot 'Confirm-TestCreation.ps1')
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
}

Describe 'Creation after receipt expiry' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid())
    $null = New-Item -ItemType Directory $cache
    $delivery = @{BaseUrl='https://example.invalid';Tenant='SOURCE';DestinationTenant='TARGET';CacheDir=$cache}
    $order = [pscustomobject]@{
      order_number='TEST1';updated_date='2026-09-08T12:00:00';progress='assigned';hold=''
      requests=@(
        [pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1"}'}
        [pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"order":{"order_number":"TEST1"},"note":"current"}'}
      )
    }
    $script:read = [pscustomobject]@{http=200;data=[pscustomobject]@{
      _id='record-1';status='error';origin_order=[pscustomobject]@{origin_order_number='TEST1'}
      routing=[pscustomobject]@{origin_tenant_name='SOURCE';destination_tenant_name='TARGET'}
    }}
    $script:calls = [Collections.Generic.List[string]]::new()
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      $script:calls.Add($Path)
      if ($ReadOnly) { return $script:read }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
  }

  It 'expires a <proof> then verifies existence and sends only the current update' -ForEach @(
    @{proof='create'},@{proof='lookup'}
  ) {
    if ($proof -eq 'create') { Confirm-TestCreation $cache TEST1 'https://example.invalid' }
    else {
      $updateOnly = $order | Select-Object *
      $updateOnly.requests = @($order.requests[1])
      $null = Add-CrossroadsDelivery -Orders @($updateOnly) -Persist $true @delivery
      $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    }
    foreach ($file in Get-ChildItem $cache -File) { $file.LastWriteTime = (Get-Date).AddHours(-49) }
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -File).Count | Should -Be 0
    $script:calls.Clear()
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $script:calls.ToArray() | Should -Be @('/v1/order/get','/v1/order/update')
    $result.status | Should -Be @('not_required','synced')
    $create = Get-ChildItem $cache -Filter '*.R10.X90.*.json' | Get-Content -Raw | ConvertFrom-Json | Where-Object message_key -eq create
    $create.not_required_reason | Should -Be order_exists
    $create.attempt_count | Should -Be 0
    $create.http | Should -BeNullOrEmpty
    $create.response | Should -BeNullOrEmpty
    $check = Get-ChildItem $cache -Filter '*.R10.X90.*.json' | Get-Content -Raw | ConvertFrom-Json | Where-Object message_key -eq creation_confirmation
    $check.status | Should -Be exists
    $check.response.destination_synced | Should -BeFalse
    Initialize-CrossroadsDelivery $cache
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery).Count | Should -Be 0
    $script:calls.Count | Should -Be 2
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 0 -ParameterFilter {$Path -eq '/v1/order/create'}
  }

  It 'reads exact scoped absence before a new create and forwards the instance on both calls' {
    $script:read = [pscustomobject]@{http=404;data=[pscustomobject]@{detail='Order not found for number: TEST1'}}
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake -OriginInstance 'source-system' @delivery)
    $script:calls.ToArray() | Should -Be @('/v1/order/get','/v1/order/create')
    $result.status | Should -Be @('synced','not_required')
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 1 -ParameterFilter {
      $ReadOnly -and $Body.order_number -ceq 'TEST1' -and $Tenant -ceq 'SOURCE' -and $DestinationTenant -ceq 'TARGET' -and $OriginInstance -ceq 'source-system'
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 1 -ParameterFilter {$AllowWrite -and $OriginInstance -ceq 'source-system'}
  }

  It 'holds a never-attempted create for <problem> without manufacturing an attempt' -ForEach @(
    @{problem='http0'},@{problem='http403'},@{problem='http500'},@{problem='generic404'},
    @{problem='wrong404'},@{problem='array404'},@{problem='parse404'},@{problem='conflicting404'},
    @{problem='wrong_order'},@{problem='wrong_route'},@{problem='missing_id'},@{problem='missing_route'}
  ) {
    switch ($problem) {
      http0 { $script:read.http=0 }
      http403 { $script:read.http=403 }
      http500 { $script:read.http=500 }
      generic404 { $script:read=[pscustomobject]@{http=404;data=[pscustomobject]@{detail='Not found'}} }
      wrong404 { $script:read=[pscustomobject]@{http=404;data=[pscustomobject]@{detail='Order not found for number: OTHER'}} }
      array404 { $script:read=[pscustomobject]@{http=404;data=[pscustomobject]@{detail=@('Order not found for number: TEST1')}} }
      parse404 { $script:read=[pscustomobject]@{http=404;parse_error='invalid JSON';data=[pscustomobject]@{detail='Order not found for number: TEST1'}} }
      conflicting404 { $script:read.http=404; $script:read.data | Add-Member detail 'Order not found for number: TEST1' }
      wrong_order { $script:read.data.origin_order.origin_order_number='OTHER' }
      wrong_route { $script:read.data.routing.destination_tenant_name='OTHER' }
      missing_id { $script:read.data._id=$null }
      missing_route { $script:read.data.routing=$null }
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    foreach ($pass in 1,2) {
      @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be waiting_for_create
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 0 -ParameterFilter {$AllowWrite}
    foreach ($item in Get-ChildItem $cache -Filter '*.json' | Get-Content -Raw | ConvertFrom-Json) {
      $item.attempt_count | Should -Be 0
      $item.attempted_at | Should -BeNullOrEmpty
      $item.state | Should -Be pending
    }
  }

  It 'preserves original create attempt evidence when a later lookup finds the order' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.R10.X00.*.json'
    $data = Get-Content $file -Raw | ConvertFrom-Json -DateKind String
    $data.attempt_count=1
    $data.attempted_at='2026-09-08T12:00:01Z'
    $data.first_attempt_at=$data.attempted_at
    $data.http=503
    $data.response=[pscustomobject]@{detail='original response'}
    $data | ConvertTo-Json -Depth 64 | Set-Content $file
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $saved = Get-ChildItem $cache -Filter '*.R10.X90.*.json' | Get-Content -Raw | ConvertFrom-Json -DateKind String | Where-Object message_key -eq create
    $saved.attempt_count | Should -Be 1
    $saved.attempted_at | Should -Be $data.attempted_at
    $saved.first_attempt_at | Should -Be $data.first_attempt_at
    $saved.http | Should -Be 503
    $saved.response.detail | Should -Be 'original response'
    $saved.status | Should -Be not_required
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 0 -ParameterFilter {$Path -eq '/v1/order/create'}
  }

  It 'leaves creates unattempted if the lookup throws' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { throw 'lookup transport interrupted' }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    { Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery } | Should -Throw '*lookup transport interrupted*'
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 0 -ParameterFilter {$AllowWrite}
    (Get-ChildItem $cache -Filter '*.R10.X00.*.json' | Get-Content -Raw | ConvertFrom-Json).attempt_count | Should -Be 0
  }
}
