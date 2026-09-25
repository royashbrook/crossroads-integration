function Get-DocumentHash([string]$Text) {
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-DocumentKey($Document, $Context) {
  $Context.scope + '_' + (Get-DocumentHash (ConvertTo-Json -InputObject @($Document.order_number, $Document.bol_number) -Compress))
}

function Assert-Document($Document) {
  foreach ($field in 'document_id', 'order_number', 'bol_number', 'file_name') {
    if ($Document.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Document.$field)) { throw "Document $field is required." }
  }
  if ($Document.file_name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.pdf$') { throw 'Invalid document filename.' }
  if ($Document.bol_number.Trim() -ieq 'undefined') { throw 'Invalid BOL number.' }
}

function Test-DocumentScope($Record, $Context, [switch]$Legacy) {
  $Record.tenant -ceq $Context.tenant -and $Record.destination_tenant -ceq $Context.destination_tenant -and
    $Record.instance -ceq $Context.instance -and ($Legacy -or $Record.base_url -ceq $Context.base_url)
}

function Get-DocumentReceipt($Document, $Context) {
  $key = Get-DocumentKey $Document $Context
  $paths = @((Join-Path $Context.directory "cache/$key.json"))
  if ($Context.legacy -and $Document.order_number -cmatch '^[1-9][0-9]*$') {
    $old = "$($Document.order_number)_$(Get-DocumentHash $Document.bol_number)"
    $paths += Join-Path $Context.directory "cache/$old.json"
  }
  foreach ($path in $paths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $record = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    if ($record.schema -ne 1 -or $record.state -cne 'sent' -or
        -not (Test-DocumentScope $record $Context -Legacy:($path -ne $paths[0])) -or
        $record.order_number -cne $Document.order_number -or $record.bol_number -cne $Document.bol_number) { throw 'Invalid document receipt scope.' }
    $date = [datetime]::Parse($record.recorded_at).ToUniversalTime()
    if ($date -gt [datetime]::UtcNow.AddMinutes(5)) { throw 'Document receipt is future-dated.' }
    if ($date.AddDays($Context.keep_days) -gt [datetime]::UtcNow) { return $true }
  }
  if ($Context.legacy -and $Document.order_number -cmatch '^[1-9][0-9]*$') {
    $hash = Get-DocumentHash $Document.bol_number
    foreach ($file in Get-ChildItem "$($Context.directory)/cache/*_$($Document.order_number)_*_$hash.sent" -ErrorAction SilentlyContinue) {
      if ($file.Length -ne 0 -or $file.Name -cnotmatch '^([0-9]{8}T[0-9]{6}Z)_[1-9][0-9]*_[1-9][0-9]*_[a-f0-9]{64}\.sent$') { throw 'Invalid legacy document marker.' }
      $date = [datetime]::ParseExact($Matches[1], "yyyyMMdd'T'HHmmss'Z'", [cultureinfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
      if ($date -gt [datetime]::UtcNow.AddMinutes(5)) { throw 'Document marker is future-dated.' }
      if ($date.AddDays($Context.keep_days) -gt [datetime]::UtcNow) { return $true }
    }
  }
  $false
}

function Write-DocumentState($Context, [string]$Path, $Record, [switch]$CreateOnly) {
  $json = $Record | ConvertTo-Json -Depth 8
  $full = Join-Path $Context.directory $Path
  if ($Context.write) {
    # The host must durably confirm its write before this run can dispatch a PDF.
    $confirmed = & $Context.write $Path $json ([bool]$CreateOnly)
    if ($confirmed -isnot [bool]) { throw 'WriteState must return one boolean confirmation.' }
    if (-not $confirmed) { return $false }
  }
  $null = New-Item -ItemType Directory -Path (Split-Path $full) -Force
  if ($CreateOnly) {
    try { $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch [IO.IOException] {
      if (Test-Path -LiteralPath $full) { return $false }
      throw
    }
    try {
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      $stream.Write($bytes); $stream.Flush($true)
    } finally { $stream.Dispose() }
  } else {
    [IO.File]::WriteAllText("$full.new", $json)
    [IO.File]::Move("$full.new", $full, $true)
  }
  $true
}

function Remove-DocumentState($Context, [string]$Path) {
  $full = Join-Path $Context.directory $Path
  if ($Context.remove) { & $Context.remove $Path (Get-Content -LiteralPath $full -Raw -ErrorAction Stop) | Out-Null }
  Remove-Item -LiteralPath $full -ErrorAction Stop
}

function Save-DocumentReceipt($Document, $Context, $Response = $null) {
  if (Get-DocumentReceipt $Document $Context) { return }
  $record = [ordered]@{
    schema = 1; state = 'sent'; recorded_at = [datetime]::UtcNow.ToString('o')
    base_url = $Context.base_url; tenant = $Context.tenant; destination_tenant = $Context.destination_tenant; instance = $Context.instance
    order_number = $Document.order_number; bol_number = $Document.bol_number
    document_id = $Document.document_id; file_name = $Document.file_name
    evidence = $(if ($null -ne $Response) { 'upload_and_photo_readback' } else { 'existing_photo_readback' }); response = $null
  }
  if ($null -ne $Response) {
    # Response bodies may contain URLs or secrets; retain only these diagnostic fields.
    Set-StrictMode -Off
    $record.response = @{
      http = [int]$Response.http; parse_error = [bool]$Response.parse_error
      status = $(if ($Response.data.status -is [string] -and $Response.data.status -cin @('synced','pending','requested','origin_mapped','master_mapped','destination_mapped','canceled','error','rejected')) { $Response.data.status } else { $null })
      log_id = $(if ($Response.data.log._id -is [string] -and $Response.data.log._id -cmatch '^[a-f0-9]{24}$') { $Response.data.log._id } else { $null })
    }
  }
  if (-not (Write-DocumentState $Context "cache/$(Get-DocumentKey $Document $Context).json" $record)) { throw 'Document receipt was not persisted.' }
}

function Clear-DocumentReceipts($Context) {
  $removed = 0
  foreach ($file in Get-ChildItem "$($Context.directory)/cache/*" -File -ErrorAction SilentlyContinue) {
    if ($removed -ge 20) { break }
    if ($file.Name -cmatch ('^' + $Context.scope + '_[a-f0-9]{64}\.json$') -or
        ($Context.legacy -and $file.Name -cmatch '^[1-9][0-9]*_[a-f0-9]{64}\.json$')) {
      $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
      $legacy = -not $record.ContainsKey('base_url')
      if (-not (Test-DocumentScope $record $Context -Legacy:$legacy)) { continue }
      if ($record.schema -ne 1 -or $record.state -cne 'sent') { throw 'Invalid document receipt.' }
      $date = [datetime]::Parse($record.recorded_at).ToUniversalTime()
    } elseif ($Context.legacy -and $file.Name -cmatch '^([0-9]{8}T[0-9]{6}Z)_[1-9][0-9]*_[1-9][0-9]*_[a-f0-9]{64}\.sent$') {
      if ($file.Length -ne 0) { throw 'Invalid legacy document marker.' }
      $date = [datetime]::ParseExact($Matches[1], "yyyyMMdd'T'HHmmss'Z'", [cultureinfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    } else { continue }
    if ($date -gt [datetime]::UtcNow.AddMinutes(5)) { throw 'Document receipt is future-dated.' }
    if ($date.AddDays($Context.keep_days) -le [datetime]::UtcNow) {
      Remove-DocumentState $Context "cache/$($file.Name)"
      $removed++
    }
  }
}

function Get-DocumentReadback($Read, $Document, $Context, [switch]$ExactFile) {
  # External optional fields are checked explicitly; absent fields must fail closed.
  Set-StrictMode -Off
  $body = $Read.data
  $origin = $body.origin_order.origin_order_number
  $destination = $body.destination_order.origin_order_number
  $routing = $body.routing
  if ($Read.http -lt 200 -or $Read.http -ge 300 -or $Read.parse_error -or
      $origin -isnot [string] -or $origin -cne $Document.order_number -or
      $routing.origin_tenant_name -isnot [string] -or $routing.origin_tenant_name -cne $Context.tenant -or
      $routing.destination_tenant_name -isnot [string] -or $routing.destination_tenant_name -cne $Context.destination_tenant -or
      $routing.destination_instance_name -isnot [string] -or $routing.destination_instance_name -cne $Context.instance -or
      $body._id -isnot [string] -or [string]::IsNullOrWhiteSpace($body._id) -or
      (-not [string]::IsNullOrWhiteSpace("$destination") -and "$destination" -cne $Document.order_number)) { return 'order_unverified' }
  $pattern = '(?:^|_)' + [regex]::Escape($Document.file_name.Substring(0, $Document.file_name.Length - 4)) +
    '(?:_[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})?\.pdf$'
  $photos = @($body.origin_order.bol_photos; $body.master_order.bol_photos; $body.destination_order.bol_photos) |
    Where-Object { $_.bol_number -is [string] -and $_.bol_number -ceq $Document.bol_number -and
      $_.file_name -is [string] -and -not [string]::IsNullOrWhiteSpace($_.file_name) }
  if ($ExactFile) {
    if (@($photos | Where-Object { $_.file_name -cmatch $pattern }).Count) { return 'visible' }
    return 'awaiting_readback'
  }
  if ($body.destination_order.destination_order_number -isnot [string] -or
      [string]::IsNullOrWhiteSpace($body.destination_order.destination_order_number) -or
      -not @($body.destination_order.bols | Where-Object { $_.bol_number -is [string] -and $_.bol_number -ceq $Document.bol_number }).Count) {
    return 'waiting_for_destination_bol'
  }
  if (@($photos).Count) { return 'already_visible' }
  'ready'
}

function Read-DocumentOrder($Document, $Context, [string]$Token) {
  $read = Invoke-CrossroadsRequest -BaseUrl $Context.base_url -Path '/v1/order/get' -Token $Token `
    -Tenant $Context.tenant -DestinationTenant $Context.destination_tenant -ReadOnly -ThrowOnTransportError `
    -Body @{ order_number = $Document.order_number } -TimeoutSec 15
  if ($read.http -in 0, 401, 403, 429 -or $read.http -ge 500) { throw "Order $($Document.order_number) read returned HTTP $($read.http)." }
  $read
}

function Send-CrossroadsDocuments {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Documents,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$BaseUrl,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$Token,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$Tenant,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$DestinationTenant,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$DestinationInstance,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$StateDirectory,
    [Parameter(Mandatory)][scriptblock]$ReadDocument,
    [scriptblock]$WriteState,
    [scriptblock]$RemoveState,
    [switch]$ReadLegacyState,
    [object[]]$PriorAttempts = @(),
    [ValidateRange(1, 3650)][int]$KeepDays = 14,
    [ValidateRange(1, 86400)][int]$BudgetSeconds = 480,
    [ValidateRange(1, 2000)][int]$MaxDocuments = 2000,
    [ValidateRange(0, 2000)][int]$MaxUploads = 0,
    [switch]$Apply
  )
  $ErrorActionPreference = 'Stop'
  # exported, so any caller can pass $null. a null pipes through Where-Object once as $_ and strict mode throws.
  $PriorAttempts = @($PriorAttempts | Where-Object { $null -ne $_ })
  $uri = [uri]$BaseUrl
  if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin 'http','https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw 'BaseUrl must be an HTTP endpoint without credentials, query or fragment.'
  }
  if ([bool]$WriteState -ne [bool]$RemoveState) { throw 'Supply both state persistence callbacks or neither.' }
  if ($Documents.Count -gt 2000) { throw 'Source selection truncated. No uploads.' }
  foreach ($document in $Documents) { Assert-Document $document }
  foreach ($attempt in $PriorAttempts) { Assert-Document $attempt }
  $context = @{ base_url = $BaseUrl.TrimEnd('/'); tenant = $Tenant; destination_tenant = $DestinationTenant
    instance = $DestinationInstance; directory = [IO.Path]::GetFullPath($StateDirectory); keep_days = $KeepDays
    legacy = [bool]$ReadLegacyState; write = $WriteState; remove = $RemoveState }
  $context.scope = Get-DocumentHash (ConvertTo-Json -InputObject @($context.base_url,$Tenant,$DestinationTenant,$DestinationInstance) -Compress)
  $documents = @($Documents | Group-Object { Get-DocumentKey $_ $context } | ForEach-Object { $_.Group[0] })
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $uploads = 0; $seen = 0
  if ($Apply) { Clear-DocumentReceipts $context }
  $claims = @{}
  foreach ($file in Get-ChildItem "$StateDirectory/claims/*.json" -ErrorAction SilentlyContinue) {
    $claim = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $legacy = $ReadLegacyState -and -not $claim.ContainsKey('base_url')
    if (-not (Test-DocumentScope $claim $context -Legacy:$legacy)) { continue }
    Assert-Document $claim
    $key = Get-DocumentKey $claim $context
    $expectedKey = $key
    if ($legacy) {
      $expectedKey = if ($claim.file_name -cmatch '^EBE-[0-9]+-[a-f0-9]{64}\.pdf$') {
        Get-DocumentHash (ConvertTo-Json -InputObject @($Tenant,$DestinationTenant,$DestinationInstance,
            $claim.order_number,$claim.bol_number,$claim.document_id,$claim.file_name) -Compress)
      } else { "$($claim.order_number)_$(Get-DocumentHash $claim.bol_number)" }
    }
    if ($file.BaseName -cne $expectedKey) { throw 'Invalid document claim key.' }
    $claims[$key] = @{ record = $claim; path = "claims/$($file.Name)" }
  }
  foreach ($key in @($claims.Keys)) {
    if ($clock.Elapsed.TotalSeconds -ge $BudgetSeconds) { break }
    $claim = $claims[$key].record
    $read = Read-DocumentOrder $claim $context $Token
    $state = Get-DocumentReadback $read $claim $context -ExactFile
    if ($state -eq 'visible' -and $Apply) {
      Save-DocumentReceipt $claim $context
      Remove-DocumentState $context $claims[$key].path
      $claims.Remove($key)
    }
    [pscustomobject]@{ order_number = $claim.order_number; bol_number = $claim.bol_number; document_id = $claim.document_id
      disposition = $(if ($state -eq 'visible') { 'claim_resolved' } else { 'awaiting_readback' }); upload_attempts = 0 }
  }
  foreach ($group in ($documents | Group-Object order_number)) {
    if ($clock.Elapsed.TotalSeconds -ge $BudgetSeconds -or $seen -ge $MaxDocuments -or ($Apply -and $MaxUploads -gt 0 -and $uploads -ge $MaxUploads)) { break }
    $read = $null
    if (@($group.Group | Where-Object { -not (Get-DocumentReceipt $_ $context) }).Count) { $read = Read-DocumentOrder $group.Group[0] $context $Token }
    foreach ($document in $group.Group) {
      if ($clock.Elapsed.TotalSeconds -ge $BudgetSeconds -or $seen -ge $MaxDocuments -or ($Apply -and $MaxUploads -gt 0 -and $uploads -ge $MaxUploads)) { break }
      $key = Get-DocumentKey $document $context
      $state = if (Get-DocumentReceipt $document $context) { 'sent_cached' } else { Get-DocumentReadback $read $document $context }
      if ($state -eq 'ready' -and ($claims.ContainsKey($key) -or @($PriorAttempts | Where-Object {
            $_.order_number -ceq $document.order_number -and $_.bol_number -ceq $document.bol_number }).Count)) { $state = 'awaiting_readback' }
      $result = [pscustomobject]@{ order_number = $document.order_number; bol_number = $document.bol_number
        document_id = $document.document_id; disposition = $state; upload_attempts = 0 }
      try {
        if ($Apply -and $state -eq 'already_visible') { Save-DocumentReceipt $document $context }
        if ($Apply -and $state -eq 'ready') {
        [byte[]]$bytes = & $ReadDocument $document
        try {
          if ($bytes.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($bytes,0,5) -cne '%PDF-') { throw 'Source returned non-PDF content.' }
          $claim = @{ base_url = $context.base_url; tenant = $Tenant; destination_tenant = $DestinationTenant; instance = $DestinationInstance
            order_number = $document.order_number; bol_number = $document.bol_number; document_id = $document.document_id
            file_name = $document.file_name; claimed_at = [datetime]::UtcNow.ToString('o') }
          if (Write-DocumentState $context "claims/$key.json" $claim -CreateOnly) {
            $result.upload_attempts = 1; $result.disposition = 'awaiting_readback'; $uploads++
            $response = Send-CrossroadsBolImage -BaseUrl $BaseUrl -Token $Token -Tenant $Tenant -DestinationTenant $DestinationTenant `
              -OrderNumber $document.order_number -BolNumber $document.bol_number -FileName $document.file_name -Bytes $bytes -AllowWrite
            $status = & { Set-StrictMode -Off; if ($response.data.status -is [string] -and
                $response.data.status -cin @('synced','pending','requested','error','rejected')) { $response.data.status } else { 'unknown' } }
            $result | Add-Member -NotePropertyMembers @{ http = $response.http; status = $status; file_name = $document.file_name }
            Start-Sleep -Seconds 3
            $after = Read-DocumentOrder $document $context $Token
            $result.disposition = Get-DocumentReadback $after $document $context -ExactFile
            if ($result.disposition -eq 'visible') {
              Save-DocumentReceipt $document $context $response
              Remove-DocumentState $context "claims/$key.json"
            }
          } else { $result.disposition = 'awaiting_readback' }
        } finally { $bytes = $null }
        }
      } finally { $result; $seen++ }
      if ($result.upload_attempts -gt 0 -and $result.disposition -ne 'visible') { throw 'Upload unresolved. No further writes this run.' }
    }
  }
}
