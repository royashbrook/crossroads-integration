Set-StrictMode -Version Latest

$RequestCodes = @{
  hold      = 0
  create    = 10
  update    = 20
  save_bol  = 30
  save_drop = 40
  status    = 90
  cancel    = 99
}

$StageCodes = @{
  assigned        = 10
  driving_to_load = 20
  arrived_at_load = 30
  loading         = 40
  driving_to_drop = 50
  arrived_at_drop = 60
  dropping        = 70
  completed_drop  = 80
  complete        = 90
}

$StateNames = @{
  X00 = 'pending'
  X40 = 'rejected'
  X80 = 'reconciled'
  X90 = 'sent'
}

function Get-RequestJson($request) {
  if ($request.PSObject.Properties['payload_json']) { return $request.payload_json }
  ConvertTo-Json -InputObject $request.payload -Depth 12 -Compress
}

function ConvertTo-CompactJson($json) {
  ConvertTo-Json -InputObject (ConvertFrom-Json $json -Depth 64 -DateKind String -NoEnumerate) -Depth 64 -Compress
}

function Get-RequestHash($baseUrl, $request, $tenant, $destinationTenant) {
  $json = Get-RequestJson $request
  $bytes = [Text.Encoding]::UTF8.GetBytes("$($baseUrl.TrimEnd('/'))|$Tenant|$DestinationTenant|$($request.path)|$json")
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLower()
}

function Get-MessageKey($request) {
  if ($request.PSObject.Properties['message_key']) { return $request.message_key }
  switch ($request.kind) {
    save_bol  { "save_bol|$($request.payload.bol_number)|$($request.payload.terminal.source_id)" }
    save_drop { "save_drop|$($request.payload.site.source_id)" }
    default   { $request.kind }
  }
}

function Write-DeliveryItem($path, $item) {
  $temp = "$path.tmp"
  try {
    $item | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temp -Encoding utf8 -ErrorAction Stop
    [IO.File]::Move($temp, $path, $true)
  }
  finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
  }
}

function Get-ReceiptKey($data) {
  "$($data.base_url)|$($data.tenant)|$($data.destination_tenant)|$($data.order_number)|$($data.message_key)"
}

function Get-DeliveryIndex($cacheDir, [switch]$Prune) {
  $legacy = @{}
  $terminal = @{}
  $pendingByHash = @{}
  $pending = [Collections.Generic.List[object]]::new()
  $receipts = @{}
  $oldFormat = $false

  foreach ($file in @(Get-ChildItem $cacheDir -File | Sort-Object Name)) {
    if ($file.Extension -eq '.cache') {
      $oldFormat = $true
      $legacy[$file.BaseName] = $true
      continue
    }
    if ($file.Name -notmatch '\.X(?<state>00|40|80|90)\.(?<hash>[0-9a-f]{64})\.json$') { continue }
    $state = $Matches.state
    $item = [pscustomobject]@{
      file = $file.FullName
      data = Get-Content $file.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String
    }
    # Match receipts from before numeric padding was removed.
    $compact = [pscustomobject]@{ path = $item.data.path; payload_json = ConvertTo-CompactJson (Get-RequestJson $item.data) }
    $item | Add-Member hashes @($item.data.hash, (Get-RequestHash $item.data.base_url $compact $item.data.tenant $item.data.destination_tenant))
    if (-not $item.data.PSObject.Properties['payload_json']) { $oldFormat = $true }
    if ($state -ne '00') {
      $key = Get-ReceiptKey $item.data
      if ($receipts.ContainsKey($key)) {
        $old = $receipts[$key]
        foreach ($hash in $old.hashes) { $terminal.Remove($hash) }
        if ($Prune) { Remove-Item -LiteralPath $old.file }
      }
      $receipts[$key] = $item
      foreach ($hash in $item.hashes) { $terminal[$hash] = $true }
      continue
    }
    $pendingByHash[$item.data.hash] = $item
    $pending.Add($item)
  }

  foreach ($item in @($pending)) {
    if (-not @($item.hashes.Where({$terminal.ContainsKey($_)})).Count) { continue }
    $pendingByHash.Remove($item.data.hash)
    $null = $pending.Remove($item)
    if ($Prune) { Remove-Item -LiteralPath $item.file }
  }

  [pscustomobject]@{
    legacy = $legacy
    terminal = $terminal
    pending_by_hash = $pendingByHash
    pending = $pending
    receipts = $receipts
    old_format = $oldFormat
  }
}

function New-DeliveryItem($order, $request, $hash, $messageKey, $baseUrl, $cacheDir, $tenant, $destinationTenant, $stateCode = 'X00', $status = $null, $response = $null) {
  $updated = [datetime]$order.updated_date
  $stage = if ($request.kind -eq 'cancel') { 99 } else { [int]$StageCodes["$($order.progress)"] }
  $requestCode = [int]$RequestCodes[$request.kind]
  $stamp = $updated.ToString('yyyyMMddTHHmmssfff')
  $file = Join-Path $cacheDir "$stamp.$($order.order_number).S$($stage.ToString('00')).R$($requestCode.ToString('00')).$stateCode.$hash.json"
  $data = [pscustomobject][ordered]@{
    order_number = $order.order_number
    source_updated = $updated.ToString('yyyy-MM-ddTHH:mm:ss.fff')
    stage_code = $stage
    request_code = $requestCode
    state = $StateNames[$stateCode]
    message_key = $messageKey
    hash = $hash
    base_url = $baseUrl.TrimEnd('/')
    tenant = $Tenant
    destination_tenant = $DestinationTenant
    kind = $request.kind
    path = $request.path
    payload_json = Get-RequestJson $request
    attempted_at = $null
    http = $null
    status = $status
    response = $response
  }
  [pscustomobject]@{ file = $file; data = $data }
}

function Initialize-CrossroadsDelivery($cacheDir) {
  Import-Module Clear-Files
  New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
  Push-Location $cacheDir
  try {
    Clear-Files ([pscustomobject]@{ keepdays = 1; purgefiles = '*.cache,*.X40.*.json,*.X80.*.json,*.X90.*.json' })
  }
  finally {
    Pop-Location
  }
  $null = Get-DeliveryIndex $cacheDir -Prune
}

function Get-CrossroadsDeliveryCursor($cacheDir) {
  $cursor = @(Get-ChildItem $cacheDir -Filter '*.cursor' -File | Sort-Object Name | Select-Object -Last 1)
  if ($cursor.Count -eq 0) { return }
  [datetime]::ParseExact($cursor[0].BaseName, 'yyyyMMddTHHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
}

function Set-CrossroadsDeliveryCursor($cacheDir, $current, $rows) {
  $latest = @($rows.updated_date | ForEach-Object { [datetime]$_ } | Sort-Object)[-1]
  if ($null -eq $current -or $latest -gt $current) {
    $stamp = $latest.ToString('yyyyMMddTHHmmssfff')
    $null > (Join-Path $cacheDir "$stamp.cursor")
    Get-ChildItem $cacheDir -Filter '*.cursor' -File |
      Where-Object BaseName -ne $stamp |
      Remove-Item
    return $latest
  }
  $current
}

function Add-CrossroadsDelivery($orders, $baseUrl, $cacheDir, $persist,
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Tenant,
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$DestinationTenant) {
  $baseUrl = $baseUrl.TrimEnd('/')
  $index = Get-DeliveryIndex $cacheDir
  $staged = [Collections.Generic.List[object]]::new()

  foreach ($order in $orders) {
    if ($null -eq $order.updated_date) { throw "Crossroads: $($order.order_number) has no updated date" }
    $updated = [datetime]$order.updated_date
    $requests = @(foreach ($request in @($order.requests)) {
      $hash = Get-RequestHash $baseUrl $request $Tenant $DestinationTenant
      $priorHash = $hash
      # Old receipts used normalized object JSON, not the SQL string.
      if ($index.old_format -and $request.PSObject.Properties['payload_json']) {
        $prior = [pscustomobject]@{ path = $request.path; payload = ConvertFrom-Json $request.payload_json -Depth 64 -DateKind String }
        $priorHash = Get-RequestHash $baseUrl $prior $Tenant $DestinationTenant
      }
      [pscustomobject]@{
        request = $request
        hash = $hash
        prior_hash = $priorHash
        key = Get-MessageKey $request
      }
    })
    $current = @{}
    foreach ($item in $requests) { $current[$item.key] = @($item.hash, $item.prior_hash) }

    if ($persist) {
      foreach ($old in @($index.pending.Where({
        "$($_.data.order_number)" -eq "$($order.order_number)" -and
        $_.data.base_url.TrimEnd('/') -eq $baseUrl -and
        $_.data.tenant -ceq $Tenant -and
        $_.data.destination_tenant -ceq $DestinationTenant -and
        [datetime]$_.data.source_updated -le $updated
      }))) {
        if ($current.ContainsKey($old.data.message_key) -and $current[$old.data.message_key] -contains $old.data.hash) { continue }
        Remove-Item -LiteralPath $old.file
        $index.pending_by_hash.Remove($old.data.hash)
      }
    }

    $cancel = @($order.requests | Where-Object kind -eq 'cancel').Count -gt 0
    if (-not [string]::IsNullOrWhiteSpace($order.hold) -and -not $cancel) {
      $request = [pscustomobject]@{
        kind = 'hold'
        path = $null
        payload = [pscustomobject][ordered]@{
          order_number = $order.order_number
          reason = $order.hold
        }
      }
      $hash = Get-RequestHash $baseUrl $request $Tenant $DestinationTenant
      if (-not $index.terminal.ContainsKey($hash)) {
        $item = New-DeliveryItem $order $request $hash 'hold' $baseUrl $cacheDir $Tenant $DestinationTenant 'X40' 'held' ([pscustomobject]@{ source = 'local'; message = $order.hold })
        if ($persist) { Write-DeliveryItem $item.file $item.data }
        $index.terminal[$hash] = $true
        $staged.Add($item)
      }
    }

    foreach ($requestItem in $requests) {
      $hashes = @($requestItem.hash, $requestItem.prior_hash)
      if (@($hashes.Where({ $index.terminal.ContainsKey($_) -or ($requestItem.request.kind -eq 'create' -and $index.legacy.ContainsKey($_)) })).Count) { continue }
      $pendingHash = $hashes.Where({$index.pending_by_hash.ContainsKey($_)}, 'First')
      if ($pendingHash.Count) {
        $staged.Add($index.pending_by_hash[$pendingHash[0]])
        continue
      }

      $item = New-DeliveryItem $order $requestItem.request $requestItem.hash $requestItem.key $baseUrl $cacheDir $Tenant $DestinationTenant
      if ($persist) { Write-DeliveryItem $item.file $item.data }
      $index.pending_by_hash[$requestItem.hash] = $item
      $index.pending.Add($item)
      $staged.Add($item)
    }
  }
  @($staged)
}

function Set-DeliveryResult($item, $stateCode, $http, $status, $response, $index) {
  $item.data.attempted_at = (Get-Date).ToUniversalTime().ToString('o')
  $item.data.http = $http
  $item.data.status = $status
  $item.data.response = $response
  $item.data.state = $StateNames[$stateCode]
  $destination = $item.file -replace '\.X00\.', ".$stateCode."
  Write-DeliveryItem $destination $item.data
  if ($stateCode -eq 'X00') { return }
  Remove-Item -LiteralPath $item.file
  $item.file = $destination
  $key = Get-ReceiptKey $item.data
  if ($index.receipts.ContainsKey($key)) {
    $old = $index.receipts[$key]
    if ($old.file -ne $destination) { Remove-Item -LiteralPath $old.file }
  }
  $index.receipts[$key] = $item
}

function Send-CrossroadsDelivery($baseUrl, $clientId, $clientSecret, $cacheDir,
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Tenant,
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$DestinationTenant) {
  $baseUrl = $baseUrl.TrimEnd('/')
  $index = Get-DeliveryIndex $cacheDir
  $pending = @($index.pending.Where({
    $_.data.base_url.TrimEnd('/') -eq $baseUrl -and
    $_.data.tenant -ceq $Tenant -and
    $_.data.destination_tenant -ceq $DestinationTenant
  }))
  if ($pending.Count -eq 0) { return }
  if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
    throw 'Crossroads: missing credentials'
  }

  $token = Get-CrossroadsToken -BaseUrl $baseUrl -TokenPath '/auth/token' `
    -ClientId $clientId -ClientSecret $clientSecret -GrantType 'password'
  foreach ($group in ($pending | Group-Object { $_.data.order_number })) {
    $blocked = $false
    $created = $false
    foreach ($item in @($group.Group | Sort-Object { $_.data.stage_code }, { $_.data.request_code }, file)) {
      if ($blocked) { continue }
      if ($item.data.kind -eq 'update' -and $created) {
        Set-DeliveryResult $item 'X90' $null 'not_required' $null $index
        [pscustomobject]@{ order_number = $item.data.order_number; kind = $item.data.kind; http = $null; ok = $true; synced = $true; state = 'sent'; status = 'not_required'; error = '' }
        continue
      }

      $response = Invoke-CrossroadsRequest -BaseUrl $baseUrl -Path $item.data.path `
        -Body (Get-RequestJson $item.data) -RawJson -Token $token -Tenant $item.data.tenant `
        -DestinationTenant $item.data.destination_tenant -AllowWrite
      $http = if ($null -eq $response.http) { 0 } else { [int]$response.http }
      $responseText = if ($null -eq $response.data) { '' } else { ConvertTo-Json -InputObject $response.data -Depth 12 -Compress }
      $responseStatus = if ($null -ne $response.data -and $response.data.PSObject.Properties['status']) { "$($response.data.status)" } else { '' }
      $errorCode = $response.data
      foreach ($field in @('log', 'detail', 'error')) {
        $errorCode = if ($null -ne $errorCode -and $errorCode.PSObject.Properties[$field]) { $errorCode.$field } else { $null }
      }
      $accepted = $http -ge 200 -and $http -lt 300
      $duplicate = $item.data.kind -eq 'create' -and ($accepted -or $http -eq 422) -and $(
        if ($errorCode) { $errorCode -eq 'request.order_already_exists' }
        else {
          $http -eq 422 -and $null -ne $response.data -and $response.data.PSObject.Properties['detail'] -and
          $response.data.detail -ceq "Duplicate order: An order with number '$($item.data.order_number)' already exists for this tenant."
        }
      )
      $alreadyApplied = $duplicate -or (
        $item.data.kind -eq 'update' -and $responseText -match '(?i)order is already loaded|order (?:has )?already been updated'
      )
      $sent = $accepted -and ([string]::IsNullOrWhiteSpace($responseStatus) -or $responseStatus -eq 'synced')
      $wrappedRetry = $responseText -match '(?i)too many requests|error code:\s*(?:408|429|5\d\d)\b|internal server error|timed? out|temporar(?:y|ily) unavailable'
      $retryable = $http -eq 0 -or $http -in @(401, 403, 408, 429) -or $http -ge 500 -or ($http -ge 300 -and $http -lt 400) -or $wrappedRetry
      $rejected = -not $sent -and -not $alreadyApplied -and -not $retryable
      $stateCode = if ($alreadyApplied) { 'X80' } elseif ($sent) { 'X90' } elseif ($rejected) { 'X40' } else { 'X00' }
      $status = if ($duplicate) {
        'duplicate'
      }
      elseif ($alreadyApplied) {
        'already_applied'
      }
      elseif (-not [string]::IsNullOrWhiteSpace($responseStatus)) {
        $responseStatus
      }
      elseif ($rejected) {
        'rejected'
      }
      else {
        'pending'
      }
      $message = if ($null -ne $response.data -and $response.data.PSObject.Properties['message']) { "$($response.data.message)" } else { '' }
      $errorMessage = if ($stateCode -in @('X80', 'X90')) { '' } elseif (-not [string]::IsNullOrWhiteSpace($message)) { $message } else { $responseText }

      Set-DeliveryResult $item $stateCode $http $status $response.data $index
      if ($item.data.kind -eq 'create' -and $stateCode -eq 'X90') { $created = $true }
      $blocked = $stateCode -eq 'X00'
      $synced = $stateCode -in @('X80', 'X90')
      [pscustomobject]@{
        order_number = $item.data.order_number
        kind = $item.data.kind
        http = $http
        ok = $synced
        synced = $synced
        state = $StateNames[$stateCode]
        status = $status
        error_code = $errorCode
        error = $errorMessage
      }
    }
  }
}
