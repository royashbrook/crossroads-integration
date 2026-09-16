BeforeAll {
  Import-Module "$PSScriptRoot/../CrossroadsIntegration/CrossroadsIntegration.psd1" -Force
  function New-ImageRead([bool]$Photo = $false) {
    $r = '{"http":200,"parse_error":null,"data":{"_id":"0123456789abcdef01234567","routing":{"origin_tenant_name":"source","destination_tenant_name":"target","destination_instance_name":"test"},"origin_order":{"origin_order_number":"123","bol_photos":[]},"master_order":{"bol_photos":[]},"destination_order":{"origin_order_number":"123","destination_order_number":"456","bols":[{"bol_number":"B1"}],"bol_photos":[]}}}' | ConvertFrom-Json
    if ($Photo) { $r.data.origin_order.bol_photos = @([pscustomobject]@{ bol_number = 'B1'; file_name = 'prefix_EBE-7_12345678-1234-1234-1234-123456789abc.pdf' }) }
    $r
  }
}

Describe 'Document delivery' {
  BeforeEach {
    $script:posted = $false
    $script:read = New-ImageRead
    $doc = [pscustomobject]@{ document_id = '7'; order_number = '123'; bol_number = 'B1'; file_name = 'EBE-7.pdf'; indexed_at = '2026-01-01' }
    $calls = [Collections.Generic.List[string]]::new()
    $params = @{ Documents = @($doc); BaseUrl = 'https://api.example/api'; Token = 'synthetic-secret'; Tenant = 'source'
      DestinationTenant = 'target'; DestinationInstance = 'test'; StateDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
      ReadDocument = { param($d) $calls.Add('pdf'); return ,[Text.Encoding]::ASCII.GetBytes('%PDF-test') }.GetNewClosure()
      WriteState = { param($path,$content,$create) $calls.Add("write:$path"); return $true }.GetNewClosure()
      RemoveState = { param($path,$content) $calls.Add("remove:$path") }.GetNewClosure() }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { if ($script:posted) { New-ImageRead -Photo $true } else { $script:read } }
    Mock Send-CrossroadsBolImage -ModuleName CrossroadsIntegration {
      $script:posted = $true
      [pscustomobject]@{ http = 200; parse_error = $null; data = [pscustomobject]@{ status = 'synced'; log = [pscustomobject]@{ _id = 'abcdef0123456789abcdef01' }; arbitrary_secret = 'must-not-persist' } }
    }
    Mock Start-Sleep -ModuleName CrossroadsIntegration { }
  }
  It 'dry-runs metadata only without source reads or state writes' {
    $r = @(Send-CrossroadsDocuments @params)
    $r.disposition | Should -Be 'ready'
    $calls.Count | Should -Be 0
    Test-Path $params.StateDirectory | Should -BeFalse
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 0
  }
  It 'persists claim before send and receipt before removing claim' {
    $r = @(Send-CrossroadsDocuments @params -Apply)
    $r.disposition | Should -Be 'visible'
    $r.upload_attempts | Should -Be 1
    $calls[0] | Should -Be 'pdf'
    $calls[1] | Should -BeLike 'write:claims/*'
    $calls[2] | Should -BeLike 'write:cache/*'
    $calls[3] | Should -BeLike 'remove:claims/*'
    @(Get-ChildItem "$($params.StateDirectory)/claims" -File).Count | Should -Be 0
    $json = Get-Content "$($params.StateDirectory)/cache/*.json" -Raw
    $json | Should -Not -Match 'synthetic-secret|arbitrary_secret|must-not-persist'
    ($json | ConvertFrom-Json).response.log_id | Should -Be 'abcdef0123456789abcdef01'
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }
  It 'suppresses source reads and API reads on a cached rerun' {
    Send-CrossroadsDocuments @params -Apply | Out-Null
    $calls.Clear()
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { throw 'cached run should not read API' }
    $r = @(Send-CrossroadsDocuments @params -Apply)
    $r.disposition | Should -Be 'sent_cached'
    $calls.Count | Should -Be 0
  }
  It 'deduplicates document rescans by order and BOL' {
    $params.Documents += [pscustomobject]@{ document_id = '8'; order_number = '123'; bol_number = 'B1'; file_name = 'EBE-8.pdf' }
    @(Send-CrossroadsDocuments @params -Apply).Count | Should -Be 1
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }
  It 'waits for a missing destination order or BOL' -ForEach @('order', 'bol') {
    if ($_ -eq 'order') { $script:read.data.destination_order.destination_order_number = '' }
    else { $script:read.data.destination_order.bols = @() }
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Be 'waiting_for_destination_bol'
    $calls.Count | Should -Be 0
  }
  It 'fails closed on wrong route, origin, instance, missing id or a malformed read' -ForEach @('route','origin','instance','id','parse','empty') {
    switch ($_) {
      route { $script:read.data.routing.destination_tenant_name = 'TARGET' }
      origin { $script:read.data.origin_order.origin_order_number = '999' }
      instance { $script:read.data.routing.destination_instance_name = 'other' }
      id { $script:read.data._id = '' }
      parse { $script:read.parse_error = 'invalid json' }
      empty { $script:read.data = $null }
    }
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Be 'order_unverified'
    $calls.Count | Should -Be 0
  }
  It 'uses any existing photo for the same BOL without fetching a PDF' {
    $script:read = New-ImageRead -Photo $true
    $script:read.data.origin_order.bol_photos[0].file_name = 'manual.pdf'
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Be 'already_visible'
    @($calls | Where-Object { $_ -eq 'pdf' }).Count | Should -Be 0
  }
  It 'keeps a claim and original transport error without a replay' {
    Mock Send-CrossroadsBolImage -ModuleName CrossroadsIntegration { throw [TimeoutException]::new('original upload timeout') }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw '*original upload timeout*'
    @(Get-ChildItem "$($params.StateDirectory)/claims/*.json").Count | Should -Be 1
    $calls.Clear()
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Contain 'awaiting_readback'
    $calls.Count | Should -Be 0
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }
  It 'emits the attempted result before propagating an upload exception' {
    Mock Send-CrossroadsBolImage -ModuleName CrossroadsIntegration { throw [TimeoutException]::new('original upload timeout') }
    $partial = [Collections.Generic.List[object]]::new()
    $errorRecord = $null
    try { Send-CrossroadsDocuments @params -Apply | ForEach-Object { $partial.Add($_) } }
    catch { $errorRecord = $_ }
    $errorRecord.Exception.Message | Should -Be 'original upload timeout'
    $partial.Count | Should -Be 1
    $partial[0].upload_attempts | Should -Be 1
    $partial[0].disposition | Should -Be 'awaiting_readback'
  }
  It 'does not dispatch when the durable claim fails' {
    $params.WriteState = { throw 'original durable-store failure' }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw '*original durable-store failure*'
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 0
  }
  It 'does not dispatch after a competing claim' {
    $params.WriteState = { return $false }
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Be 'awaiting_readback'
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 0
  }
  It 'retains the claim when receipt persistence fails' {
    $params.WriteState = { param($path) if ($path.StartsWith('cache/')) { throw 'original receipt failure' }; return $true }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw '*original receipt failure*'
    @(Get-ChildItem "$($params.StateDirectory)/claims/*.json").Count | Should -Be 1
    @($calls | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
  }
  It 'resolves a prior claim without a second POST even outside source selection' {
    Mock Send-CrossroadsBolImage -ModuleName CrossroadsIntegration { throw 'unknown write outcome' }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw
    $params.Documents = @()
    $script:read = New-ImageRead -Photo $true
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Be 'claim_resolved'
    @(Get-ChildItem "$($params.StateDirectory)/claims/*.json").Count | Should -Be 0
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }
  It 'requires exact attempted filename metadata after POST' {
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { $script:read }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw '*Upload unresolved*'
    @(Get-ChildItem "$($params.StateDirectory)/claims/*.json").Count | Should -Be 1
  }
  It 'keeps source exceptions at their original message' {
    $params.ReadDocument = { throw 'original PDF retrieval error' }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw '*original PDF retrieval error*'
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 0
  }
  It 'uses configurable receipt retention without changing payload policy' {
    Send-CrossroadsDocuments @params -Apply | Out-Null
    $file = Get-ChildItem "$($params.StateDirectory)/cache/*.json"
    $record = Get-Content $file -Raw | ConvertFrom-Json
    $record.recorded_at = [datetime]::UtcNow.AddDays(-3).ToString('o')
    $record | ConvertTo-Json -Depth 8 | Set-Content $file
    @(Send-CrossroadsDocuments @params -KeepDays 14).disposition | Should -Be 'sent_cached'
    @(Send-CrossroadsDocuments @params -KeepDays 2).disposition | Should -Be 'already_visible'
    $calls.Clear()
    Send-CrossroadsDocuments @params -KeepDays 2 -Apply | Out-Null
    $calls[0] | Should -BeLike 'remove:cache/*'
    @($calls | Where-Object { $_ -eq 'pdf' }).Count | Should -Be 0
  }
  It 'isolates receipt keys by API, tenant and destination instance' -ForEach @('BaseUrl','Tenant','DestinationInstance') {
    Send-CrossroadsDocuments @params -Apply | Out-Null
    $params[$_] += '-other'
    @(Send-CrossroadsDocuments @params).disposition | Should -Not -Be 'sent_cached'
  }
  It 'honors explicitly scoped legacy receipts' {
    Send-CrossroadsDocuments @params -Apply | Out-Null
    $file = Get-ChildItem "$($params.StateDirectory)/cache/*.json"
    $r = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
    $r.Remove('base_url')
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('B1'))).ToLowerInvariant()
    $r | ConvertTo-Json -Depth 8 | Set-Content "$($params.StateDirectory)/cache/123_$hash.json"
    Remove-Item $file
    @(Send-CrossroadsDocuments @params -ReadLegacyState).disposition | Should -Be 'sent_cached'
    $r.tenant = 'other'
    $r | ConvertTo-Json -Depth 8 | Set-Content "$($params.StateDirectory)/cache/123_$hash.json"
    { Send-CrossroadsDocuments @params -ReadLegacyState } | Should -Throw '*receipt scope*'
  }
  It 'honors legacy empty markers only when explicitly opted in' {
    $null = New-Item -ItemType Directory "$($params.StateDirectory)/cache" -Force
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('B1'))).ToLowerInvariant()
    $name = [datetime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'") + "_123_7_$hash.sent"
    [IO.File]::WriteAllText("$($params.StateDirectory)/cache/$name", '')
    @(Send-CrossroadsDocuments @params).disposition | Should -Be 'ready'
    @(Send-CrossroadsDocuments @params -ReadLegacyState).disposition | Should -Be 'sent_cached'
  }
  It 'honors a caller-scoped historical probe without a replay' {
    @(Send-CrossroadsDocuments @params -PriorAttempts @($doc) -Apply).disposition | Should -Be 'awaiting_readback'
    $calls.Count | Should -Be 0
  }
  It 'rejects source overflow before any IO' {
    $params.Documents = @($doc) * 2001
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw '*truncated*'
    $calls.Count | Should -Be 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0
  }
  It 'supports a persistent local store without callbacks' {
    $params.Remove('WriteState'); $params.Remove('RemoveState')
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Be 'visible'
    @(Send-CrossroadsDocuments @params -Apply).disposition | Should -Be 'sent_cached'
  }
  It 'honors the upload count without interpreting zero as stop-at-zero' -ForEach @(0,1) {
    $params.Documents = @(1..3 | ForEach-Object { [pscustomobject]@{ document_id = "$_"; order_number = '123'; bol_number = "B$_"; file_name = "EBE-$_.pdf" } })
    $script:sentBols = [Collections.Generic.List[string]]::new()
    Mock Send-CrossroadsBolImage -ModuleName CrossroadsIntegration {
      $script:sentBols.Add($BolNumber)
      [pscustomobject]@{ http = 200; parse_error = $null; data = [pscustomobject]@{ status = 'synced'; log = $null } }
    }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      $r = New-ImageRead
      $r.data.destination_order.bols = @(1..3 | ForEach-Object { [pscustomobject]@{ bol_number = "B$_" } })
      $r.data.origin_order.bol_photos = @($script:sentBols | ForEach-Object { [pscustomobject]@{ bol_number = $_; file_name = "EBE-$($_.Substring(1)).pdf" } })
      $r
    }
    $r = @(Send-CrossroadsDocuments @params -Apply -MaxUploads $_)
    $r.Count | Should -Be $(if ($_ -eq 0) { 3 } else { 1 })
    @($r | Where-Object disposition -ne visible).Count | Should -Be 0
  }
  It 'does not purge expired claims with expired receipts' {
    Mock Send-CrossroadsBolImage -ModuleName CrossroadsIntegration { throw 'uncertain upload' }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw
    $file = Get-ChildItem "$($params.StateDirectory)/claims/*.json"
    $r = Get-Content $file -Raw | ConvertFrom-Json
    $r.claimed_at = [datetime]::UtcNow.AddDays(-30).ToString('o')
    $r | ConvertTo-Json -Depth 8 | Set-Content $file
    Send-CrossroadsDocuments @params -Apply -KeepDays 1 | Out-Null
    Test-Path $file | Should -BeTrue
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }
  It 'keeps a legacy claim protected after moving to scoped keys' {
    Mock Send-CrossroadsBolImage -ModuleName CrossroadsIntegration { throw 'uncertain upload' }
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw
    $file = Get-ChildItem "$($params.StateDirectory)/claims/*.json"
    $r = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
    $r.Remove('base_url')
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('B1'))).ToLowerInvariant()
    $r | ConvertTo-Json -Depth 8 | Set-Content "$($params.StateDirectory)/claims/123_$hash.json"
    Remove-Item $file
    $results = @(Send-CrossroadsDocuments @params -Apply -ReadLegacyState)
    $results.disposition | Should -Contain 'awaiting_readback'
    Should -Invoke Send-CrossroadsBolImage -ModuleName CrossroadsIntegration -Times 1 -Exactly
  }
  It 'rejects credential-bearing API URLs before IO' {
    $params.BaseUrl = 'https://user:password@api.example/api'
    { Send-CrossroadsDocuments @params -Apply } | Should -Throw '*without credentials*'
    $calls.Count | Should -Be 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0
  }
}
