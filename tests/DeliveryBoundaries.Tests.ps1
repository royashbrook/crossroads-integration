BeforeAll {
  . (Join-Path $PSScriptRoot 'Confirm-TestCreation.ps1')
  $module = Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force -PassThru
}

Describe 'Delivery boundaries' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid())
    $null = New-Item -ItemType Directory $cache
    $delivery = @{ BaseUrl='https://example.invalid'; Tenant='SOURCE'; DestinationTenant='TARGET'; CacheDir=$cache }
    $order = [pscustomobject]@{
      order_number='TEST1'; updated_date='2026-01-01T01:00:00'; progress='assigned'; hold=''
      requests=@([pscustomobject]@{kind='status';path='/v1/order/update_status';message_key='status';payload_json='{"order_number":"TEST1"}'})
    }
  }

  It 'rejects repeated order snapshots before touching pending work' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $before = @(Get-ChildItem $cache -File | Get-FileHash).Hash
    foreach ($count in 2,3) {
      { Add-CrossroadsDelivery -Orders (@($order) * $count) -Persist $true @delivery } | Should -Throw '*one complete latest snapshot*'
      @(Get-ChildItem $cache -File | Get-FileHash).Hash | Should -Be $before
    }
  }

  It 'retires a pending item from both in-memory indexes' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    & $module {
      param($cache, $order)
      $index = Get-DeliveryIndex $cache
      $order.updated_date = '2026-01-01T02:00:00'
      $order.requests[0].payload_json = '{"order_number":"TEST1","value":2}'
      $null = Add-Delivery @($order) 'https://example.invalid' $cache $true SOURCE TARGET $index
      $index.pending.Count | Should -Be 1
      $index.pending_by_hash.Count | Should -Be 1
      Test-Path $index.pending[0].file | Should -BeTrue
    } $cache $order
  }

  It 'keeps malformed HTTP success pending with its actual response' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ http=200; data='accepted'; parse_error='Invalid JSON' }
    }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $r = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $r.http | Should -Be 200
    $r.state | Should -Be pending
    $r.status | Should -Be invalid_response
    $r.error | Should -Be 'Invalid JSON'
    $saved = Get-Content (Get-ChildItem $cache -Filter '*.X00.*.json').FullName -Raw | ConvertFrom-Json
    $saved.http | Should -Be 200
    $saved.response | Should -Be 'accepted'
  }

  It 'does not reconcile text that failed response parsing' {
    & $module {
      $r = Get-DeliveryResponse ([pscustomobject]@{http=200;data='order is already loaded';parse_error='Invalid JSON'}) update TEST1
      $r.state_code | Should -Be X00
    }
  }

  It 'keeps an asynchronous pending response retryable and later sends it' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=200;data=[pscustomobject]@{status='pending';message='Processing is taking longer than expected.'}} }
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $r = Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery
    $r.state | Should -Be pending
    $r.status | Should -Be pending
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}} }
    (Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery).state | Should -Be sent
  }

  It 'restores previously misclassified pending acknowledgments without losing their response' {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.X00.*.json'
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $data.state='rejected'; $data.status='pending'; $data.http=200
    $data.response=[pscustomobject]@{status='pending';message='Still processing'}
    $old = $file.FullName -replace '\.X00\.', '.X40.'
    $data | ConvertTo-Json -Depth 64 | Set-Content $old
    Remove-Item $file
    Initialize-CrossroadsDelivery $cache
    $restored = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $restored.hash | Should -Be $data.hash
    $restored.response.message | Should -Be 'Still processing'
    $restored.state | Should -Be pending
    Test-Path $old | Should -BeFalse
  }

  It 'does not revive an acknowledgment superseded by a <replacement> payload' -ForEach @(@{replacement='pending'},@{replacement='sent'}) {
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $file = Get-ChildItem $cache -Filter '*.X00.*.json'
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $data.state='rejected'; $data.status='pending'; $data.http=200
    $data | ConvertTo-Json -Depth 64 | Set-Content ($file.FullName -replace '\.X00\.', '.X40.')
    Remove-Item $file
    $order.updated_date='2026-01-01T02:00:00'
    $order.requests[0].payload_json='{"order_number":"TEST1","value":2}'
    $new = @(Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery)[0]
    if ($replacement -eq 'sent') {
      $new.data.state='sent'; $new.data.status='synced'
      $new.data | ConvertTo-Json -Depth 64 | Set-Content ($new.file -replace '\.X00\.', '.X90.')
      Remove-Item $new.file
    }
    Initialize-CrossroadsDelivery $cache
    Test-Path $file.FullName | Should -BeFalse
    @(Get-ChildItem $cache -Filter '*.X00.*.json').Count | Should -Be $(if ($replacement -eq 'pending') {1} else {0})
  }

  It 'retains HTTP error classification for non-JSON bodies' {
    & $module {
      foreach ($http in 400,404,422) {
        (Get-DeliveryResponse ([pscustomobject]@{http=$http;data='invalid request';parse_error='Invalid JSON'}) update TEST1).state_code | Should -Be X40
      }
      foreach ($http in 401,403,429,503) {
        (Get-DeliveryResponse ([pscustomobject]@{http=$http;data='unavailable';parse_error='Invalid JSON'}) update TEST1).state_code | Should -Be X00
      }
    }
  }

  It 'still sends update after a duplicate create' {
    Confirm-TestCreation $cache TEST1 'https://example.invalid'
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'fake' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/create') {
        return [pscustomobject]@{http=422;data=[pscustomobject]@{detail="Duplicate order: An order with number 'TEST1' already exists for this tenant."}}
      }
      [pscustomobject]@{http=200;data=[pscustomobject]@{status='synced'}}
    }
    $order.requests = @(
      [pscustomobject]@{kind='create';path='/v1/order/create';message_key='create';payload_json='{"origin_order_number":"TEST1"}'},
      [pscustomobject]@{kind='update';path='/v1/order/update';message_key='update';payload_json='{"order":{"order_number":"TEST1"}}'}
    )
    $null = Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery
    $r = @(Send-CrossroadsDelivery -ClientId fake -ClientSecret fake @delivery)
    $r[0].state | Should -Be reconciled
    $r[1].status | Should -Be synced
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Exactly -Times 1 -ParameterFilter {$Path -eq '/v1/order/update'}
  }
}
