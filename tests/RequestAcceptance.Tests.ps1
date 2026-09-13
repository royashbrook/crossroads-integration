BeforeAll {
  $module = Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force -PassThru
  function New-RetainedResponse($kind = 'update', $status = 'error') {
    $types = @{create='create_order';update='update_order';save_bol='progress_bol';save_drop='progress_drop';status='progress_status';cancel='cancel_order'}
    [pscustomobject]@{http=200;data=[pscustomobject]@{
      status=$status;message='Downstream processing needs repair'
      log=[pscustomobject]@{
        _id='log-1';saga_id='operation-1';saga_type=$types[$kind];status='failed'
        metadata=[pscustomobject]@{origin_order_number='TEST1';group_id='TEST1';crossroads_order_id='record-1'}
        routing=[pscustomobject]@{origin_tenant_name='SOURCE';destination_tenant_name='TARGET'}
        detail=[pscustomobject]@{error='request.order_not_synced'}
      }
    }}
  }
}

Describe 'Durable request acceptance' {
  It 'accepts a retained <kind> operation without claiming downstream success' -ForEach @(
    @{kind='update'},@{kind='save_bol'},@{kind='save_drop'},@{kind='status'},@{kind='cancel'}
  ) {
    foreach ($status in @('error','pending')) {
      $response = New-RetainedResponse $kind $status
      $result = & $module {param($r,$k) Get-DeliveryResponse $r $k TEST1 SOURCE TARGET} $response $kind
      $result.state_code | Should -Be X90
      $result.status | Should -Be accepted
      $result.error | Should -BeNullOrEmpty
      $response.data.status | Should -Be $status
      $response.data.log.detail.error | Should -Be request.order_not_synced
    }
  }

  It 'does not infer acceptance from <problem>' -ForEach @(
    @{problem='missing_log'},@{problem='missing_log_id'},@{problem='missing_saga_id'},@{problem='wrong_kind'},
    @{problem='missing_metadata'},@{problem='missing_order_id'},@{problem='wrong_order'},@{problem='wrong_group'},
    @{problem='missing_route'},@{problem='wrong_source'},@{problem='wrong_destination'},@{problem='route_case'},
    @{problem='http_422'},@{problem='http_403'},@{problem='http_429'},@{problem='http_500'},
    @{problem='timeout'},@{problem='parse_error'},@{problem='unknown_status'},@{problem='invalid_id_type'}
  ) {
    $response = New-RetainedResponse
    switch ($problem) {
      missing_log { $response.data.log = $null }
      missing_log_id { $response.data.log._id = '' }
      missing_saga_id { $response.data.log.saga_id = ' ' }
      wrong_kind { $response.data.log.saga_type = 'progress_bol' }
      missing_metadata { $response.data.log.metadata = $null }
      missing_order_id { $response.data.log.metadata.crossroads_order_id = '' }
      wrong_order { $response.data.log.metadata.origin_order_number = 'OTHER' }
      wrong_group { $response.data.log.metadata.group_id = 'OTHER' }
      missing_route { $response.data.log.routing = $null }
      wrong_source { $response.data.log.routing.origin_tenant_name = 'OTHER' }
      wrong_destination { $response.data.log.routing.destination_tenant_name = 'OTHER' }
      route_case { $response.data.log.routing.origin_tenant_name = 'source' }
      http_422 { $response.http = 422 }
      http_403 { $response.http = 403 }
      http_429 { $response.http = 429 }
      http_500 { $response.http = 500 }
      timeout { $response.http = 0 }
      parse_error { $response | Add-Member parse_error 'invalid JSON' }
      unknown_status { $response.data.status = 'unknown' }
      invalid_id_type { $response.data.log._id = @('id1','id2') }
    }
    $result = & $module {param($r) Get-DeliveryResponse $r update TEST1 SOURCE TARGET} $response
    $result.state_code | Should -Not -Be X90
    $result.status | Should -Not -Be accepted
  }

  It 'keeps unscoped callers on the existing classifier' {
    $response = New-RetainedResponse
    (& $module {param($r) Get-DeliveryResponse $r update TEST1} $response).state_code | Should -Be X40
  }
}

Describe 'Accepted delivery sequencing and cache reconciliation' {
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
    $script:responses = @{}
    foreach ($kind in @('create','update','save_bol','save_drop','status')) { $script:responses[$kind] = New-RetainedResponse $kind }
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($ReadOnly) {
        return [pscustomobject]@{http=200;data=[pscustomobject]@{
          _id='record-1';status='error';origin_order=[pscustomobject]@{origin_order_number='TEST1'}
          routing=[pscustomobject]@{origin_tenant_name='SOURCE';destination_tenant_name='TARGET'}
        }}
      }
      $kind = if ($Path -eq '/v1/order/update_status') { 'status' } else { $Path.Split('/')[-1] }
      $script:responses[$kind]
    }
  }

  It 'advances all retained events in order and does not resend unchanged data' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.kind | Should -Be @('update','save_bol','save_drop','status')
    $result.status | Should -Be @('accepted','accepted','accepted','accepted')
    @(Get-ChildItem $cache -Filter '*.X00.*.json').Count | Should -Be 0
    Initialize-CrossroadsDelivery $cache
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 4 -Exactly -ParameterFilter { $AllowWrite }
    $order.updated_date = '2026-09-08T13:00:00'
    $order.requests[0].payload_json = '{"order":{"order_number":"TEST1","note":"corrected"}}'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery).kind | Should -Be @('update')
  }

  It 'reconciles a stored <state> receipt without sending or changing payload and attempt evidence' -ForEach @(
    @{state='rejected';code='X40'},@{state='pending';code='X00'}
  ) {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.R20.X00.*.json'
    $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $data.state = $state
    $data.status = 'error'
    $data.http = 200
    $data.response = $script:responses.update.data
    $data.attempt_count = 3
    $data.attempted_at = '2026-09-08T12:01:00Z'
    & $module {param($p,$d) Write-DeliveryItem $p $d} $file.FullName $data
    if ($code -eq 'X40') { Move-Item $file.FullName ($file.FullName -replace '\.X00\.', '.X40.') }
    Initialize-CrossroadsDelivery $cache
    $migrated = Get-ChildItem $cache -Filter '*.R20.X90.*.json' | Get-Content -Raw | ConvertFrom-Json -DateKind String
    $migrated.status | Should -Be accepted
    $migrated.response.status | Should -Be error
    $migrated.hash | Should -Be $data.hash
    $migrated.payload_json | Should -Be $data.payload_json
    $migrated.attempt_count | Should -Be 3
    $migrated.attempted_at | Should -Be $data.attempted_at
    $before = @(Get-ChildItem $cache -File | Sort-Object Name | Get-FileHash).Hash
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -File | Sort-Object Name | Get-FileHash).Hash | Should -Be $before
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly
    Should -Invoke Get-CrossroadsToken -ModuleName CrossroadsIntegration -Times 0 -Exactly
  }

  It 'does not migrate a receipt with <problem>' -ForEach @(
    @{problem='wrong_route'},@{problem='invalid_response'},@{problem='failed_http'},@{problem='missing_log'}
  ) {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.R20.X00.*.json'
    $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $data.http = 200
    $data.status = 'error'
    $data.response = $script:responses.update.data
    switch ($problem) {
      wrong_route { $data.response.log.routing.destination_tenant_name = 'OTHER' }
      invalid_response { $data.status = 'invalid_response' }
      failed_http { $data.http = 503 }
      missing_log { $data.response.log = $null }
    }
    & $module {param($p,$d) Write-DeliveryItem $p $d} $file.FullName $data
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R20.X90.*.json').Count | Should -Be 0
    Test-Path $file.FullName | Should -BeTrue
  }

  It 'keeps creation on the existing strict gate even with a retained-operation log' {
    $order.requests = @([pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"order_number":"TEST1"}'})
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].state | Should -Be rejected
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R10.X90.*.json').Count | Should -Be 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $ReadOnly }
  }
}
