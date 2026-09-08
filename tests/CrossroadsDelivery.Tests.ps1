BeforeAll {
  . (Join-Path $PSScriptRoot 'Confirm-TestCreation.ps1')
  Import-Module (Join-Path $PSScriptRoot 'TMWReference.psm1') -Force
  Import-Module CrossroadsClient -MinimumVersion 1.0.2 -Force
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
  $delivery = @{ Tenant = 'SOURCE'; DestinationTenant = 'TARGET' }
  $rows = @(Import-Csv (Join-Path $PSScriptRoot 'fixture-rows.csv'))
  $orders = @(ConvertTo-CrossroadsOrder $rows)
}

Describe 'Crossroads delivery' {
  BeforeEach {
    $script:cache = Join-Path $TestDrive ([guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:cache -Force | Out-Null
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'test-token' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced'; message = $null } }
    }
  }

  It 'rejects a <label> destination without changing existing state' -ForEach @(
    @{ label = 'null'; url = $null }
    @{ label = 'empty'; url = '' }
    @{ label = 'whitespace'; url = " `t " }
  ) {
    $null = Add-CrossroadsDelivery $orders 'http://localhost:8808' $script:cache $true @delivery
    $null = Set-CrossroadsDeliveryCursor $script:cache $null $orders
    $before = @(Get-ChildItem $script:cache -File | Sort-Object Name | Get-FileHash).Hash

    { Add-CrossroadsDelivery $orders $url $script:cache $true @delivery } | Should -Throw '*baseUrl*'
    { Send-CrossroadsDelivery $url test test $script:cache @delivery } | Should -Throw '*baseUrl*'

    @(Get-ChildItem $script:cache -File | Sort-Object Name | Get-FileHash).Hash | Should -Be $before
    Should -Invoke Get-CrossroadsToken -ModuleName CrossroadsIntegration -Times 0 -Exactly
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly
  }

  It 'rejects a blank destination before touching a new cache' {
    $cache = Join-Path $TestDrive 'not-created'
    { Add-CrossroadsDelivery $orders '' $cache $true @delivery } | Should -Throw '*baseUrl*'
    { Send-CrossroadsDelivery '' test test $cache @delivery } | Should -Throw '*baseUrl*'
    Test-Path $cache | Should -BeFalse
    Should -Invoke Get-CrossroadsToken -ModuleName CrossroadsIntegration -Times 0 -Exactly
  }

  It 'suppresses an identical successful replay' {
    $null = Add-CrossroadsDelivery $orders 'http://localhost:8808' $script:cache $true @delivery
    $first = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)
    $staged = @(Add-CrossroadsDelivery $orders 'http://localhost:8808' $script:cache $true @delivery)
    $second = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)

    $first.Count | Should -Be 8
    $staged.Count | Should -Be 0
    $second.Count | Should -Be 0
    @(Get-ChildItem $script:cache -Filter '*.X00.*.json').Count | Should -Be 0
    @(Get-ChildItem $script:cache -Filter '*.X90.*.json').Count | Should -Be 8
    (Get-Content (Get-ChildItem $script:cache -Filter '*.R10.X90.*.json')[0].FullName -Raw | ConvertFrom-Json).http | Should -Be 200
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 6
    Should -Invoke Get-CrossroadsToken -ModuleName CrossroadsIntegration -Times 1 -ParameterFilter {
      $ClientId -eq 'test' -and $ClientSecret -eq 'test' -and $GrantType -eq 'password' -and $TokenPath -eq '/auth/token'
    }
  }

  It 'retries pending requests without another source row' {
    $script:fail = $true
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($script:fail) { return [pscustomobject]@{ http = 500; data = 'failed' } }
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced'; message = $null } }
    }

    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $first = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)
    $script:fail = $false
    $second = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)

    $first.Count | Should -Be 1
    $second.Count | Should -Be 3
    @(Get-ChildItem $script:cache -Filter '*.X00.*.json').Count | Should -Be 0
  }

  It 'retries destination rate limits wrapped in HTTP 200' {
    $script:fail = $true
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($script:fail) {
        return [pscustomobject]@{
          http = 200
          data = [pscustomobject]@{ status = 'error'; message = 'The destination returned error code: 429: Too many requests.' }
        }
      }
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced'; message = $null } }
    }

    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $first = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)
    $script:fail = $false
    $second = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)

    $first.Count | Should -Be 1
    $first[0].state | Should -Be 'pending'
    $second.Count | Should -Be 3
    @(Get-ChildItem $script:cache -Filter '*.X00.*.json').Count | Should -Be 0
  }

  It 'does not treat every create 422 as a duplicate' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = 'missing required field' } }
    }

    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $first = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)
    $second = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)

    $first[0].synced | Should -BeFalse
    $first.Count | Should -Be 1
    $first.state | Should -Be @('rejected')
    $second.Count | Should -Be 1
    $second[0].status | Should -Be 'waiting_for_create'
    @(Get-ChildItem $script:cache -Filter '*.X40.*.json').Count | Should -Be 1
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $AllowWrite }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $ReadOnly }
  }

  It 'accepts only an explicit duplicate create 422' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = "Duplicate order: An order with number '900001' already exists for this tenant." } }
    }

    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $first = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)
    $second = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)

    $first[0].status | Should -Be 'duplicate'
    $first[0].state | Should -Be 'reconciled'
    $second.Count | Should -Be 1
    $second[0].status | Should -Be 'waiting_for_create'
  }

  It 'classifies create responses by code or exact order identity' -ForEach @(
    @{ Code = 'request.order_already_exists'; Http = 200; Detail = 'changed wording'; Expected = 'reconciled' }
    @{ Code = 'request.two_drops_for_site'; Http = 422; Detail = "Duplicate order: An order with number '900001' already exists for this tenant."; Expected = 'rejected' }
    @{ Code = $null; Http = 422; Detail = 'duplicate product in request'; Expected = 'rejected' }
    @{ Code = $null; Http = 422; Detail = "Duplicate order: An order with number 'other' already exists for this tenant."; Expected = 'rejected' }
    @{ Code = 'request.order_already_exists'; Http = 500; Detail = 'duplicate order'; Expected = 'pending' }
  ) {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{
        http = $Http
        data = [pscustomobject]@{
          status = 'error'
          detail = $Detail
          log = [pscustomobject]@{ detail = [pscustomobject]@{ error = $Code } }
        }
      }
    }
    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $result = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)[0]
    $result.state | Should -Be $Expected
    $result.error_code | Should -Be $Code
    $receipt = Get-ChildItem $script:cache -Filter '*.R10.*.json'
    (Get-Content $receipt.FullName -Raw | ConvertFrom-Json).response.detail | Should -Be $Detail
  }

  It 'does not treat an already-loaded supply rejection as delivered' {
    Confirm-TestCreation $script:cache '900001'
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/create') {
        return [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = "Duplicate order: An order with number '$(($Body | ConvertFrom-Json).origin_order_number)' already exists for this tenant." } }
      }
      if ($Path -eq '/v1/order/update') {
        return [pscustomobject]@{
          http = 200
          data = [pscustomobject]@{
            status = 'error'
            message = "Supply Change Automatically Rejected. The Order is already Loaded, and the 'Supply Change' rule only allows changes until the order is Shift Started"
          }
        }
      }
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced'; message = $null } }
    }

    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $results = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)
    $update = $results.Where({$_.kind -eq 'update'})[0]

    $update.synced | Should -BeFalse
    $update.status | Should -Be 'error'
    @(Get-ChildItem $script:cache -Filter '*.R20.X00.*.json').Count | Should -Be 0
    $receipt = @(Get-ChildItem $script:cache -Filter '*.R20.X40.*.json')
    $receipt.Count | Should -Be 1
    (Get-Content $receipt[0].FullName -Raw | ConvertFrom-Json).state | Should -Be 'rejected'
    $results[-1].status | Should -Be waiting_for_update
    @(Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery).Count | Should -Be 1
  }

  It 'records update rejections and holds dependent requests' {
    Confirm-TestCreation $script:cache '900001'
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/create') {
        return [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = "Duplicate order: An order with number '$(($Body | ConvertFrom-Json).origin_order_number)' already exists for this tenant." } }
      }
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'error'; message = 'terminal mapping missing' } }
    }

    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $results = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)
    $update = $results.Where({$_.kind -eq 'update'})[0]

    $update.synced | Should -BeFalse
    $update.state | Should -Be 'rejected'
    $results.Count | Should -Be 3
    @(Get-ChildItem $script:cache -Filter '*.R20.X40.*.json').Count | Should -Be 1
    @(Get-ChildItem $script:cache -Filter '*.R90.X00.*.json').Count | Should -Be 1
    $results[-1].status | Should -Be waiting_for_update
    @(Get-ChildItem $script:cache -Filter '*.R20.X80.*.json').Count | Should -Be 0
    @(Get-ChildItem $script:cache -Filter '*.R20.X90.*.json').Count | Should -Be 0
  }

  It 'sends independent drops but holds completion after a rejected BOL' {
    Confirm-TestCreation $script:cache '900002'
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/create') {
        return [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = "Duplicate order: An order with number '$(($Body | ConvertFrom-Json).origin_order_number)' already exists for this tenant." } }
      }
      if ($Path -eq '/v1/order/update') {
        return [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced' } }
      }
      if ($Path -eq '/v1/order/save_bol') {
        return [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = 'tank mapping missing' } }
      }
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced'; message = $null } }
    }

    $order = $orders.Where({$_.order_number -eq '900002'})
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $results = @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery)

    $results.kind | Should -Be @('create', 'update', 'save_bol', 'save_drop', 'status')
    $results.Where({$_.kind -eq 'save_bol'})[0].state | Should -Be 'rejected'
    $results.Where({$_.kind -eq 'save_drop'})[0].state | Should -Be 'sent'
    $results.Where({$_.kind -eq 'status'})[0].status | Should -Be 'waiting_for_details'
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -Exactly -ParameterFilter { $Path -eq '/v1/order/update_status' }
  }

  It 'stages changed content after a terminal rejection' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = 'mapping missing' } }
    }
    $row = $rows[0] | Select-Object *
    $first = @(ConvertTo-CrossroadsOrder @($row))
    $null = Add-CrossroadsDelivery $first 'http://localhost:8808' $script:cache $true @delivery
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery

    $row.updated_date = ([datetime]$row.updated_date).AddMinutes(1)
    $row.source_status = 'STD'
    $row.progress_status = 'driving_to_load'
    $second = @(ConvertTo-CrossroadsOrder @($row))
    $staged = @(Add-CrossroadsDelivery $second 'http://localhost:8808' $script:cache $true @delivery)

    $staged.Count | Should -Be 2
    @(Get-ChildItem $script:cache -Filter '*.R90.X40.*.json').Count | Should -Be 0
    @(Get-ChildItem $script:cache -Filter '*.R90.X00.*.json').Count | Should -Be 1
  }

  It 'does not resend unchanged content after a timestamp-only update' {
    $row = $rows[0] | Select-Object *
    $order = @(ConvertTo-CrossroadsOrder @($row))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery

    $row.updated_date = ([datetime]$row.updated_date).AddMinutes(1)
    $replay = @(ConvertTo-CrossroadsOrder @($row))

    @(Add-CrossroadsDelivery $replay 'http://localhost:8808' $script:cache $true @delivery).Count | Should -Be 0
  }

  It 'delivers a correction back to a previously sent value' {
    $script:created = $false
    $script:remoteVolume = 0
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      if ($Path -eq '/v1/order/create' -and $script:created) {
        return [pscustomobject]@{ http = 422; data = [pscustomobject]@{ detail = "Duplicate order: An order with number '$(($Body | ConvertFrom-Json).origin_order_number)' already exists for this tenant." } }
      }
      if ($Path -in @('/v1/order/create', '/v1/order/update')) {
        $script:created = $true
        $script:remoteVolume = ($Body | ConvertFrom-Json).drops[0].volume
      }
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced' } }
    }
    $row = $rows[0] | Select-Object *
    foreach ($volume in @(5000, 4900, 5000)) {
      $row.volume = $volume
      $row.updated_date = ([datetime]$row.updated_date).AddMinutes(15)
      $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($row)) 'http://localhost:8808' $script:cache $true @delivery
      $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    }
    $script:remoteVolume | Should -Be 5000
    @(Get-ChildItem $script:cache -Filter '*.R20.X90.*.json').Count | Should -Be 1
    @(Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($row)) 'http://localhost:8808' $script:cache $true @delivery).Count | Should -Be 0
  }

  It 'retains the previous receipt while its replacement is retrying' {
    $row = $rows[0] | Select-Object *
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($row)) 'http://localhost:8808' $script:cache $true @delivery
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    $receipt = (Get-ChildItem $script:cache -Filter '*.R10.X90.*.json')[0]
    $row.volume = 4900
    $row.updated_date = ([datetime]$row.updated_date).AddMinutes(15)
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($row)) 'http://localhost:8808' $script:cache $true @delivery
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ http = 500; data = 'failed' }
    }
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    Test-Path $receipt.FullName | Should -BeTrue
    @(Get-ChildItem $script:cache -Filter '*.R10.X00.*.json').Count | Should -Be 1
  }

  It 'preserves valid pending JSON when writing a receipt is interrupted' {
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($rows[0])) 'http://localhost:8808' $script:cache $true @delivery
    $script:interrupt = $true
    Mock Set-Content -ModuleName CrossroadsIntegration {
      if ($script:interrupt) {
        [IO.File]::WriteAllText($LiteralPath, '{')
        throw 'simulated interruption'
      }
      [IO.File]::WriteAllText($LiteralPath, ($Value -join [Environment]::NewLine))
    }
    { Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery } | Should -Throw '*simulated interruption*'
    foreach ($file in Get-ChildItem $script:cache -Filter '*.X00.*.json') {
      { Get-Content $file.FullName -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
    $script:interrupt = $false
    @(Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery).Count | Should -Be 3
    @(Get-ChildItem $script:cache -Filter '*.tmp').Count | Should -Be 0
  }

  It 'honors a receipt if interrupted before removing the pending file' {
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($rows[0])) 'http://localhost:8808' $script:cache $true @delivery
    $file = (Get-ChildItem $script:cache -Filter '*.R10.X00.*.json')[0]
    $receipt = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $receipt.state = 'sent'
    $receipt | ConvertTo-Json -Depth 16 | Set-Content ($file.FullName -replace '\.X00\.', '.X90.')
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0 -ParameterFilter { $Path -eq '/v1/order/create' }
  }

  It 'prunes historical receipts by request identity on startup' {
    $row = $rows[0] | Select-Object *
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($row)) 'http://localhost:8808' $script:cache $true @delivery
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    $old = (Get-ChildItem $script:cache -Filter '*.R20.X90.*.json')[0]
    $oldJson = Get-Content $old.FullName -Raw
    $row.volume = 4900
    $row.updated_date = ([datetime]$row.updated_date).AddMinutes(15)
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($row)) 'http://localhost:8808' $script:cache $true @delivery
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    Set-Content $old.FullName $oldJson
    $module = Get-Module CrossroadsIntegration
    $null = & $module { param($path) Get-DeliveryIndex $path -Prune } $script:cache
    Test-Path $old.FullName | Should -BeFalse
    @(Get-ChildItem $script:cache -Filter '*.R20.X90.*.json').Count | Should -Be 1
    $row.volume = 5000
    $row.updated_date = ([datetime]$row.updated_date).AddMinutes(15)
    @(Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder @($row)) 'http://localhost:8808' $script:cache $true @delivery).Count | Should -BeGreaterThan 0
  }

  It 'keeps distinct BOL and site receipts when one is corrected' {
    $multi = @($rows[2] | Select-Object *; $rows[2] | Select-Object *)
    $multi[1].bol_number = 'SECOND-BOL'
    $multi[1].site_id = 'SECOND-SITE'
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder $multi) 'http://localhost:8808' $script:cache $true @delivery
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    $multi[0].net_volume = 7800
    foreach ($row in $multi) { $row.updated_date = ([datetime]$row.updated_date).AddMinutes(15) }
    $null = Add-CrossroadsDelivery @(ConvertTo-CrossroadsOrder $multi) 'http://localhost:8808' $script:cache $true @delivery
    $null = Send-CrossroadsDelivery 'http://localhost:8808' test test $script:cache @delivery
    @(Get-ChildItem $script:cache -Filter '*.R30.X90.*.json').Count | Should -Be 2
    @(Get-ChildItem $script:cache -Filter '*.R40.X90.*.json').Count | Should -Be 2
  }

  It 'replaces an older pending status with the latest payload' {
    $row = $rows[0] | Select-Object *
    $first = @(ConvertTo-CrossroadsOrder @($row))
    $null = Add-CrossroadsDelivery $first 'http://localhost:8808' $script:cache $true @delivery

    $row.updated_date = ([datetime]$row.updated_date).AddMinutes(1)
    $row.source_status = 'STD'
    $row.progress_status = 'driving_to_load'
    $second = @(ConvertTo-CrossroadsOrder @($row))
    $null = Add-CrossroadsDelivery $second 'http://localhost:8808' $script:cache $true @delivery

    $statuses = @(Get-ChildItem $script:cache -Filter '*.R90.X00.*.json')
    $statuses.Count | Should -Be 1
    ((Get-Content $statuses[0].FullName -Raw | ConvertFrom-Json).payload_json | ConvertFrom-Json).progress_status | Should -Be 'driving_to_load'
  }

  It 'uses sortable request state filenames' {
    $order = @(ConvertTo-CrossroadsOrder @($rows[0]))
    $null = Add-CrossroadsDelivery $order 'http://localhost:8808' $script:cache $true @delivery

    (Get-ChildItem $script:cache -Filter '*.R10.X00.*.json')[0].Name |
      Should -Match '^\d{8}T\d{9}\.900001\.S10\.R10\.X00\.[0-9a-f]{64}\.json$'
  }

  It 'records an invalid window as a local rejection' {
    $row = $rows[0] | Select-Object *
    $row.window_end = $row.window_start
    $order = @(ConvertTo-CrossroadsOrder @($row))[0]

    $order.hold | Should -Be 'delivery window end must be after start'
    $order.requests.Count | Should -Be 0
    @(Add-CrossroadsDelivery @($order) 'http://localhost:8808' $script:cache $true @delivery).Count | Should -Be 1
    @(Add-CrossroadsDelivery @($order) 'http://localhost:8808' $script:cache $true @delivery).Count | Should -Be 0
    $receipt = @(Get-ChildItem $script:cache -Filter '*.R00.X40.*.json')
    $receipt.Count | Should -Be 1
    (Get-Content $receipt[0].FullName -Raw | ConvertFrom-Json).state | Should -Be 'rejected'
  }

  It 'does not move the source cursor backward' {
    $current = [datetime]'2026-09-01T09:00:00'
    $actual = Set-CrossroadsDeliveryCursor $TestDrive $current @([pscustomobject]@{ updated_date = '2026-09-01T08:59:00' })

    $actual | Should -Be $current
    @(Get-ChildItem $TestDrive -Filter '*.cursor').Count | Should -Be 0
  }

  It 'writes the newest returned source update to the cursor' {
    $null > (Join-Path $TestDrive '20260901T080000000.cursor')
    $actual = Set-CrossroadsDeliveryCursor $TestDrive $null @(
      [pscustomobject]@{ updated_date = '2026-09-01T08:59:00' }
      [pscustomobject]@{ updated_date = '2026-09-01T09:01:00' }
    )

    $actual | Should -Be ([datetime]'2026-09-01T09:01:00')
    @(Get-ChildItem $TestDrive -Filter '*.cursor').Name | Should -Be '20260901T090100000.cursor'
  }
}
