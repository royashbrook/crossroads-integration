BeforeAll {
  . (Join-Path $PSScriptRoot 'Confirm-TestCreation.ps1')
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force

  function New-RetentionItem($cache, $number, $state = 'X90') {
    & (Get-Module CrossroadsIntegration) {
      param($cache, $number, $state)
      $order = [pscustomobject]@{ order_number=$number; updated_date='2020-01-01T00:00:00'; progress='assigned' }
      $request = [pscustomobject]@{ kind='update'; path='/v1/order/update'; payload_json="{`"order_number`":`"$number`"}" }
      $hash = Get-RequestHash 'https://example.invalid' $request SOURCE TARGET
      $item = New-DeliveryItem $order $request $hash 'update' 'https://example.invalid' $cache SOURCE TARGET $state
      Write-DeliveryItem $item.file $item.data
      $item.file
    } $cache $number $state
  }
}

Describe 'Persisted order receipt age' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid())
    $null = New-Item -ItemType Directory $cache
    $script:clock = [datetime]'2026-10-12T12:00:00Z'
    Mock Get-Date -ModuleName CrossroadsIntegration { $script:clock }
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { throw 'No HTTP in cleanup' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration { throw 'No HTTP in cleanup' }
  }

  It 'records UTC age for a new <state> receipt, independently of source age' -ForEach @(
    @{state='X40'}, @{state='X80'}, @{state='X90'}
  ) {
    $file = New-RetentionItem $cache AGE1 $state
    $data = Get-Content $file -Raw | ConvertFrom-Json -DateKind String
    $data.recorded_at | Should -BeExactly $script:clock.ToUniversalTime().ToString('o')
    $data.source_updated | Should -BeExactly '2020-01-01T00:00:00.000'
    Initialize-CrossroadsDelivery $cache
    Test-Path $file | Should -BeTrue
  }

  It 'never age-prunes pending files or cursors' {
    $file = New-RetentionItem $cache PENDING X00
    $cursor = Join-Path $cache '20200101T000000000.cursor'
    $null > $cursor
    foreach ($path in $file,$cursor) { (Get-Item $path).LastWriteTime = (Get-Date).AddYears(-5) }
    Initialize-CrossroadsDelivery $cache
    Test-Path $file | Should -BeTrue
    Test-Path $cursor | Should -BeTrue
    (Get-Content $file -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain recorded_at
  }

  It 'uses stored age, retaining 47h, exact 48h and future timestamps but removing 49h' {
    foreach ($hours in 47,48,49,-1) {
      $file = Get-Item (New-RetentionItem $cache "AGE$hours")
      Set-TestReceiptAge $file $script:clock.AddHours(-$hours)
      $file.LastWriteTime = Get-Date
    }
    Initialize-CrossroadsDelivery $cache
    $remaining = @(Get-ChildItem $cache -File | Get-Content -Raw | ConvertFrom-Json)
    $remaining.order_number | Should -Contain AGE47
    $remaining.order_number | Should -Contain AGE48
    $remaining.order_number | Should -Contain AGE-1
    $remaining.order_number | Should -Not -Contain AGE49
  }

  It 'does not expire a recent receipt just because its filesystem age is old' {
    $file = New-RetentionItem $cache RECENT
    (Get-Item $file).LastWriteTime = (Get-Date).AddYears(-5)
    Initialize-CrossroadsDelivery $cache
    Test-Path $file | Should -BeTrue
  }

  It 'backfills unknown legacy age once without changing its evidence' {
    $file = New-RetentionItem $cache LEGACY
    $data = Get-Content $file -Raw | ConvertFrom-Json -DateKind String
    $data.PSObject.Properties.Remove('recorded_at')
    $data.attempted_at = '2020-01-01T00:00:00Z'
    $data.attempt_count = 3
    $before = $data | ConvertTo-Json -Depth 64 -Compress
    $data | ConvertTo-Json -Depth 64 | Set-Content $file
    Initialize-CrossroadsDelivery $cache
    $saved = Get-Content $file -Raw | ConvertFrom-Json -DateKind String
    $saved.recorded_at | Should -BeExactly $script:clock.ToUniversalTime().ToString('o')
    $saved.PSObject.Properties.Remove('recorded_at')
    ($saved | ConvertTo-Json -Depth 64 -Compress) | Should -BeExactly $before
    $hash = (Get-FileHash $file).Hash
    $script:clock = $script:clock.AddHours(47)
    (Get-Item $file).LastWriteTime = Get-Date
    Initialize-CrossroadsDelivery $cache
    (Get-FileHash $file).Hash | Should -BeExactly $hash
    $script:clock = $script:clock.AddHours(2)
    Initialize-CrossroadsDelivery $cache
    Test-Path $file | Should -BeFalse
    Should -Invoke Get-CrossroadsToken -ModuleName CrossroadsIntegration -Times 0
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 0
  }

  It 'backfills null age with the same grace period' {
    $file = New-RetentionItem $cache NULLAGE
    $data = Get-Content $file -Raw | ConvertFrom-Json -DateKind String
    $data | Add-Member recorded_at $null -Force
    $data | ConvertTo-Json -Depth 64 | Set-Content $file
    Initialize-CrossroadsDelivery $cache
    (Get-Content $file -Raw | ConvertFrom-Json -DateKind String).recorded_at | Should -BeExactly $script:clock.ToUniversalTime().ToString('o')
  }

  It 'keeps legacy hash identity while persisting and expiring its grace period' {
    $file = Join-Path $cache "$('a'*64).cache"
    $null > $file
    Initialize-CrossroadsDelivery $cache
    (Get-Content $file -Raw | ConvertFrom-Json -DateKind String).recorded_at | Should -BeExactly $script:clock.ToUniversalTime().ToString('o')
    (& (Get-Module CrossroadsIntegration) { param($cache) (Get-DeliveryIndex $cache).legacy.ContainsKey('a'*64) } $cache) | Should -BeTrue
    $script:clock = $script:clock.AddHours(49)
    (Get-Item $file).LastWriteTime = Get-Date
    Initialize-CrossroadsDelivery $cache
    Test-Path $file | Should -BeFalse
  }

  It 'does not delete receipts if any stored timestamp is malformed' {
    $expired = Get-Item (New-RetentionItem $cache OLD)
    Set-TestReceiptAge $expired $script:clock.AddHours(-49)
    $invalid = New-RetentionItem $cache INVALID
    $data = Get-Content $invalid -Raw | ConvertFrom-Json -DateKind String
    $data | Add-Member recorded_at 'not-a-timestamp' -Force
    $data | ConvertTo-Json -Depth 64 | Set-Content $invalid
    { Initialize-CrossroadsDelivery $cache } | Should -Throw
    Test-Path $expired.FullName | Should -BeTrue
    Test-Path $invalid | Should -BeTrue
  }

  It 'retains an expired dependency without renewing its age, then expires it when released' {
    $receipt = Get-Item (New-RetentionItem $cache DEPENDENCY)
    Set-TestReceiptAge $receipt $script:clock.AddHours(-49)
    $data = Get-Content $receipt.FullName -Raw | ConvertFrom-Json -DateKind String
    $pending = New-RetentionItem $cache DEPENDENT X00
    $queued = Get-Content $pending -Raw | ConvertFrom-Json -DateKind String
    $queued | Add-Member requires @($data.hash)
    $queued | ConvertTo-Json -Depth 64 | Set-Content $pending
    $before = (Get-FileHash $receipt.FullName).Hash
    Initialize-CrossroadsDelivery $cache
    (Get-FileHash $receipt.FullName).Hash | Should -BeExactly $before
    Remove-Item $pending
    Initialize-CrossroadsDelivery $cache
    Test-Path $receipt.FullName | Should -BeFalse
  }

  It 'records the current terminal transition after an old receipt was requeued' {
    $file = New-RetentionItem $cache REQUEUED X00
    $data = Get-Content $file -Raw | ConvertFrom-Json -DateKind String
    $data | Add-Member recorded_at $script:clock.AddDays(-30).ToUniversalTime().ToString('o')
    $data | ConvertTo-Json -Depth 64 | Set-Content $file
    & (Get-Module CrossroadsIntegration) {
      param($cache)
      $index = Get-DeliveryIndex $cache
      Set-DeliveryResult $index.pending[0] X90 200 synced ([pscustomobject]@{status='synced'}) $index
    } $cache
    (Get-ChildItem $cache -Filter '*.X90.*.json' | Get-Content -Raw | ConvertFrom-Json -DateKind String).recorded_at | Should -BeExactly $script:clock.ToUniversalTime().ToString('o')
  }

  It 'expires a persisted receipt after a real fresh clone resets file times' {
    $old = Get-Item (New-RetentionItem $cache CLONEOLD)
    $recent = Get-Item (New-RetentionItem $cache CLONERECENT)
    Set-TestReceiptAge $old $script:clock.AddHours(-49)
    Set-TestReceiptAge $recent $script:clock.AddHours(-47)
    & git init -q $cache
    if ($LASTEXITCODE) { throw 'fixture git init failed' }
    & git -C $cache add .
    if ($LASTEXITCODE) { throw 'fixture git add failed' }
    & git -C $cache -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'receipt fixture (refs #51)'
    if ($LASTEXITCODE) { throw 'fixture git commit failed' }
    $clone = Join-Path $TestDrive 'fresh-clone'
    & git clone -q $cache $clone
    if ($LASTEXITCODE) { throw 'fixture git clone failed' }
    (Get-Item (Join-Path $clone $old.Name)).LastWriteTimeUtc | Should -BeGreaterThan $script:clock.AddHours(-1)
    Initialize-CrossroadsDelivery $clone
    Test-Path (Join-Path $clone $old.Name) | Should -BeFalse
    Test-Path (Join-Path $clone $recent.Name) | Should -BeTrue
    (Get-Content (Join-Path $clone $recent.Name) -Raw | ConvertFrom-Json -DateKind String).recorded_at | Should -BeExactly $script:clock.AddHours(-47).ToUniversalTime().ToString('o')
  }
}
