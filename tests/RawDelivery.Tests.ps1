BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
  $delivery = @{ Tenant = 'SOURCE'; DestinationTenant = 'TARGET' }
  $payload = '{"order":{"origin_order_number":"123"},"site":{"source_id":"SITE"},"details":[{"quantity":7900.0}]}'
  $raw = '{"order":{"origin_order_number":"123"},"site":{"source_id":"SITE"},"details":[{"quantity":7900.0000000000000000}]}'
}

Describe 'Opaque request delivery' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory $cache
    $old = [pscustomobject]@{
      order_number = '123'; updated_date = '2026-09-05T16:00:00'; progress = 'complete'; hold = $null
      requests = @([pscustomobject]@{ kind = 'save_drop'; path = '/v1/order/save_drop'; payload = ConvertFrom-Json $payload })
    }
    $new = $old | Select-Object *
    $new.requests = @([pscustomobject]@{ kind = 'save_drop'; path = '/v1/order/save_drop'; message_key = 'save_drop|SITE'; payload_json = $raw })
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'test-token' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced' } } }
  }

  It 'hashes, persists and sends the exact SQL string' {
    $item = @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery)[0]
    $text = "https://example.invalid|SOURCE|TARGET|/v1/order/save_drop|$raw"
    $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLower()
    $item.data.hash | Should -BeExactly $expected
    (Get-Content $item.file -Raw | ConvertFrom-Json).payload_json | Should -BeExactly $raw
    $null = Send-CrossroadsDelivery 'https://example.invalid' test test $cache @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $RawJson -and $Body -ceq $raw }
    @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery).Count | Should -Be 0
  }

  It 'honors old terminal receipts without suppressing a later changed quantity' {
    $item = @(Add-CrossroadsDelivery @($old) 'https://example.invalid' $cache $true @delivery)[0]
    $null = Send-CrossroadsDelivery 'https://example.invalid' test test $cache @delivery
    $file = @(Get-ChildItem $cache -Filter '*.X90.*.json')[0].FullName
    $data = Get-Content $file -Raw | ConvertFrom-Json -DateKind String
    $data | Add-Member payload (ConvertFrom-Json $data.payload_json -DateKind String)
    $data.PSObject.Properties.Remove('payload_json')
    $data | ConvertTo-Json -Depth 16 | Set-Content $file
    @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery).Count | Should -Be 0
    $new.requests[0].payload_json = $raw.Replace('7900.', '7901.')
    $new.updated_date = '2026-09-05T16:15:00'
    @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery).Count | Should -Be 1
  }

  It 'keeps a matching old pending request and can still send it' {
    $item = @(Add-CrossroadsDelivery @($old) 'https://example.invalid' $cache $true @delivery)[0]
    $data = $item.data
    $data | Add-Member payload (ConvertFrom-Json $data.payload_json -DateKind String)
    $data.PSObject.Properties.Remove('payload_json')
    $data | ConvertTo-Json -Depth 16 | Set-Content $item.file
    $pending = @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery)
    $pending.Count | Should -Be 1
    $pending[0].file | Should -BeExactly $item.file
    @(Get-ChildItem $cache -File).Count | Should -Be 1
    $null = Send-CrossroadsDelivery 'https://example.invalid' test test $cache @delivery
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter { $RawJson -and $Body -ceq $payload }
    @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery).Count | Should -Be 0
  }

  It 'recognizes a padded receipt without suppressing a later A to B to A change' {
    $null = Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery
    $null = Send-CrossroadsDelivery 'https://example.invalid' test test $cache @delivery
    $new.requests[0].payload_json = $payload
    @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery).Count | Should -Be 0
    $new.updated_date = '2026-09-05T16:15:00'
    $new.requests[0].payload_json = $payload.Replace('7900.', '7800.')
    @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery).Count | Should -Be 1
    $null = Send-CrossroadsDelivery 'https://example.invalid' test test $cache @delivery
    $new.updated_date = '2026-09-05T16:30:00'
    $new.requests[0].payload_json = $payload
    @(Add-CrossroadsDelivery @($new) 'https://example.invalid' $cache $true @delivery).Count | Should -Be 1
  }
}
