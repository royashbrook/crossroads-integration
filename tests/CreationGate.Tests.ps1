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

  It 'waits without writes when readback cannot confirm creation' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    foreach ($pass in 1,2) {
      $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
      $result.Count | Should -Be 1
      $result[0].status | Should -Be waiting_for_create
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $AllowWrite }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 2 -Exactly -ParameterFilter { $ReadOnly }
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

  It 'expires ordinary sent receipts but keeps creation confirmation' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $order.requests[0].kind = 'update'
    $order.requests[0].path = '/v1/order/update'
    $order.requests[0].message_key = 'update'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $receipts = @(Get-ChildItem $cache -Filter '*.X90.*.json')
    $receipts.Count | Should -Be 2
    foreach ($receipt in $receipts) { $receipt.LastWriteTime = (Get-Date).AddDays(-30) }
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R10.X90.*.json').Count | Should -Be 1
    @(Get-ChildItem $cache -Filter '*.R20.X90.*.json').Count | Should -Be 0
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
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $AllowWrite }
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

  It 'recovers expired creation proof from a matching synced destination readback' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($ReadOnly) {
        return [pscustomobject]@{http=200;data=[pscustomobject]@{
          status='synced';origin_order=[pscustomobject]@{origin_order_number='TEST1'}
          destination_order=[pscustomobject]@{origin_order_number='TEST1';destination_order_number='DEST1'}
        }}
      }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].state | Should -Be sent
    $proof = Get-ChildItem $cache -Filter '*.R10.X90.*.json' | Get-Content -Raw | ConvertFrom-Json
    $proof.path | Should -Be '/v1/order/get'
    $proof.response.verified_by | Should -Be order_get
    foreach ($file in Get-ChildItem $cache -Filter '*.json') { $file.LastWriteTime = (Get-Date).AddDays(-30) }
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R10.X90.*.json').Count | Should -Be 1
    $order.requests[0].payload_json = '{"order":{"order_number":"TEST1"},"actual":"2026-09-08T12:15:00Z"}'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $ReadOnly -and $Body.order_number -eq 'TEST1' -and -not $Body.ContainsKey('order') -and $Tenant -ceq 'SOURCE' -and $DestinationTenant -ceq 'TARGET' }
  }

  It 'rejects readback proof with <problem>' -ForEach @(@{problem='wrong_order'},@{problem='no_destination'},@{problem='not_synced'}) {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      $body = [pscustomobject]@{
        status='synced';origin_order=[pscustomobject]@{origin_order_number='TEST1'}
        destination_order=[pscustomobject]@{origin_order_number='TEST1';destination_order_number='DEST1'}
      }
      switch ($problem) {
        wrong_order { $body.destination_order.origin_order_number='OTHER' }
        no_destination { $body.destination_order.destination_order_number=$null }
        not_synced { $body.status='error' }
      }
      [pscustomobject]@{http=200;data=$body}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be waiting_for_create
    @(Get-ChildItem $cache -Filter '*.R10.X90.*.json').Count | Should -Be 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $AllowWrite }
  }

  It 'retains required receipts and refreshes dependencies when a rejected detail is corrected' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $order.progress = 'complete'
    $order.requests = @(
      [pscustomobject]@{kind='save_bol';path='/v1/order/save_bol';message_key='bol:B1';payload_json='{"bol_number":"B1","quantity":100}'}
      [pscustomobject]@{kind='save_drop';path='/v1/order/save_drop';message_key='drop:S1';payload_json='{"site":"S1","quantity":100}'}
      [pscustomobject]@{kind='status';path='/v1/order/update_status';message_key='status';payload_json='{"progress_status":"complete"}'}
    )
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/save_bol' -and $Body -match ':100') { return [pscustomobject]@{http=422;data=[pscustomobject]@{detail='mapping missing'}} }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.status | Should -Be @('rejected','synced','waiting_for_details')
    foreach ($file in Get-ChildItem $cache -Filter '*.json') { $file.LastWriteTime = (Get-Date).AddDays(-30) }
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R40.X90.*.json').Count | Should -Be 1
    @(Get-ChildItem $cache -Filter '*.R30.X40.*.json').Count | Should -Be 1
    $order.requests[0].payload_json = '{"bol_number":"B1","quantity":101}'
    $order.updated_date = '2026-09-08T12:15:00'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.kind | Should -Be @('save_bol','status')
    $result.state | Should -Be @('sent','sent')
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $Path -eq '/v1/order/update_status' }
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R40.X90.*.json').Count | Should -Be 0
  }

  It 'holds an older completion without a recorded dependency snapshot' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $order.progress = 'complete'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.X00.*.json'
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $data.PSObject.Properties.Remove('requires')
    $data | ConvertTo-Json -Depth 64 | Set-Content $file
    @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)[0].status | Should -Be waiting_for_details
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly
  }

  It 'holds details across runs until the current supply update succeeds' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $order.progress = 'complete'
    $order.requests = @(
      [pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"terminal":"bad"}'}
      [pscustomobject]@{kind='save_bol';path='/v1/order/save_bol';message_key='bol:B1';payload_json='{"bol_number":"B1","quantity":100}'}
      [pscustomobject]@{kind='save_drop';path='/v1/order/save_drop';message_key='drop:S1';payload_json='{"site":"S1","quantity":100}'}
      [pscustomobject]@{kind='status';path='/v1/order/update_status';message_key='status';payload_json='{"progress_status":"complete"}'}
    )
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/update' -and $Body -match 'bad') { return [pscustomobject]@{http=422;data=[pscustomobject]@{detail='no supply'}} }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.status | Should -Be @('rejected','waiting_for_update','waiting_for_update','waiting_for_details')
    foreach ($file in Get-ChildItem $cache -Filter '*.json') { $file.LastWriteTime = (Get-Date).AddDays(-30) }
    Initialize-CrossroadsDelivery $cache
    @(Get-ChildItem $cache -Filter '*.R20.X40.*.json').Count | Should -Be 1
    $null = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly
    $order.updated_date = '2026-09-08T12:15:00'
    $order.requests[0].payload_json = '{"terminal":"good"}'
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.kind | Should -Be @('update','save_bol','save_drop','status')
    $result.state | Should -Be @('sent','sent','sent','sent')
    @(Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery).Count | Should -Be 0
  }

  It 'holds legacy pending details behind a visible failed update' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $order.requests = @(
      [pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"terminal":"bad"}'}
      [pscustomobject]@{kind='save_bol';path='/v1/order/save_bol';message_key='bol:B1';payload_json='{"bol_number":"B1"}'}
    )
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=422;data=[pscustomobject]@{detail='no supply'}} }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.R30.X00.*.json'
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $data.PSObject.Properties.Remove('requires')
    $data | ConvertTo-Json -Depth 64 | Set-Content $file
    foreach ($pass in 1,2) {
      $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
      $result[-1].status | Should -Be waiting_for_update
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly
    @((Get-Content $file -Raw | ConvertFrom-Json).requires).Count | Should -Be 1
  }

  It 'uses a fresh create-covered update as prerequisite proof' {
    $order.requests = @(
      [pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1","drops":[]}'}
      [pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"order":{"order_number":"TEST1"},"drops":[]}'}
    ) + $order.requests
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.status | Should -Be @('synced','not_required','synced')
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter {$Path -eq '/v1/order/update'}
  }

  It 'accepts a synced update even when its informational message says already loaded' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    $order.requests = @([pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"order":{"order_number":"TEST1"}}'}) + $order.requests
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced';message='order is already loaded'}} }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $result = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $result.state | Should -Be @('sent','sent')
  }
}
