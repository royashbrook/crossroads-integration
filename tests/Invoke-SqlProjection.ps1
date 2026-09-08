$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
Import-Module (Join-Path $PSScriptRoot 'TMWReference.psm1') -Force

$fixture = @(Import-Csv (Join-Path $PSScriptRoot 'fixture-rows.csv'))
$rows = [Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt 23; $i++) {
  $row = $fixture[$(if ($i -in 1,6,12,13,18,22) { 2 } else { 0 })] | Select-Object *
  $row.order_number = "$(920000 + $i)"
  switch ($i) {
    2 { $row.drop_status = 'DNE'; $row.drop_depart = '2026-09-02T14:00:00Z' }
    3 { $row.lift_status = 'DNE' }
    4 { $row.supplier_id = '' }
    5 { $row.window_end = $row.window_start }
    6 { $row.bol_number = '' }
    7 { $row.source_status = 'CAN' }
    8 { $row.site_name = ' '; $row.terminal_name = ''; $row.product_name = ''; $row.supplier_name = '' }
    9 { $row.product_name = "quote `" slash \ unicode $([char]0x00e9)`nline" }
    10 { $row.product_name = 'large text ' * 1200 }
    11 { $row.progress_status = '' }
    15 { $row.volume = '5000.5' }
    16 { $row.volume = '5001.5' }
    17 { $row.product_id = '' }
    18 { $row.net_volume = '1234.5678901234567'; $row.gross_volume = '1234.56' }
    19 { $row.volume = '2500.2' }
    20 { $row.volume = '2500.7' }
    21 { $row.volume = '-2.5' }
    22 { $row.net_volume = '7.899000000000000e+003'; $row.gross_volume = '1.2345678901234567e+003' }
  }
  $row | Add-Member tank_allocations @(@{tank_id='3';quantity=[double]$row.volume})
  $rows.Add($row)
  if ($i -in 2,12,13,14,19,20) {
    $next = $row | Select-Object *
    switch ($i) {
      2 { $next.site_id = 'NEXT'; $next.drop_status = 'OPN'; $next.drop_depart = '2026-09-02T20:00:00Z' }
      12 { $next.site_id = 'NEXT'; $next.drop_depart = '2026-09-02T21:00:00Z' }
      13 { $next.bol_number = 'BOL2'; $next.terminal_id = 'TERM3' }
      14 { $next.supplier_id = 'SUP3'; $next.volume = '1000' }
      19 { $next.volume = '2500.3' }
      20 { $next.volume = '2500.8' }
    }
    $rows.Add($next)
  }
}

$password = [guid]::NewGuid().ToString('N') + 'aA1!'
"::add-mask::$password"
$container = "crossroads-sql-$PID"
$connectionString = "Server=127.0.0.1,1433;Database=master;User ID=sa;Password=$password;Encrypt=False;Connect Timeout=2"
try {
  $env:MSSQL_SA_PASSWORD = $password
  docker run -d --name $container -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD -p 127.0.0.1:1433:1433 mcr.microsoft.com/mssql/server:2022-latest
  if ($LASTEXITCODE) { throw 'SQL container failed to start.' }
  $ready = $false
  for ($attempt = 0; $attempt -lt 60 -and -not $ready; $attempt++) {
    $connection = [Data.SqlClient.SqlConnection]::new($connectionString)
    try { $connection.Open(); $ready = $true }
    catch { Start-Sleep -Seconds 2 }
    finally { $connection.Dispose() }
  }
  if (-not $ready) { throw 'SQL container did not become ready.' }

  $source = ConvertTo-Json -InputObject @($rows) -Depth 64 -Compress -EscapeHandling EscapeNonAscii
  $sql = Join-Path (Get-Module CrossroadsIntegration).ModuleBase 'Adapters/TMW/Get-Requests.sql'
  $actual = @(Get-CrossroadsSqlData -SqlFile $sql -ConnectionString $connectionString -Parameters @{Source=$source})
  $expected = @(ConvertTo-CrossroadsOrder @($rows))
  if ($actual.Count -ne $expected.Count) { throw 'SQL order count differs.' }
  $requests = 0
  foreach ($order in $expected) {
    $result = @($actual.Where({$_.order_number -eq $order.order_number}))[0]
    if ($order.order_number -eq '920021') {
      if ($result.requests.Count -ne 0 -or $result.hold) { throw 'Nonpositive freight became a request or hold.' }
      continue
    }
    $order.requests = @($order.requests.Where({$_.kind -ne 'status' -or $null -ne $_.payload.actual}))
    if ($order.order_number -eq '920006') {
      if ($result.requests.kind -contains 'save_bol' -or $result.requests.kind -contains 'status' -or $result.requests.kind -notcontains 'save_drop') { throw 'Invalid BOL suppressed a valid drop or allowed completion.' }
      continue
    }
    foreach ($drop in $order.requests.Where({$_.kind -eq 'save_drop'})) {
      foreach ($detail in $drop.payload.details) {
        $detail | Add-Member tank ([pscustomobject]@{source_id=$drop.payload.site.source_id;tank_id='3'})
      }
    }
    if ([datetime]$result.updated_date -ne [datetime]$order.updated_date -or $result.progress -cne $order.progress -or $result.hold -cne $order.hold) { throw "Envelope differs: $($order.order_number)" }
    $normalized = @($result.requests | ForEach-Object { [pscustomobject]@{kind=$_.kind;path=$_.path;payload=ConvertFrom-Json $_.payload_json -Depth 64 -DateKind String} })
    $left = ConvertTo-Json -InputObject @($order.requests) -Depth 64 -Compress
    $right = ConvertTo-Json -InputObject $normalized -Depth 64 -Compress
    if ($left -cne $right) { throw "Payload differs: $($order.order_number)" }
    $requests += $normalized.Count
    $create = @($normalized.Where({$_.kind -eq 'create'}))
    $update = @($normalized.Where({$_.kind -eq 'update'}))
    if ($create.Count -and $update.Count) {
      foreach ($field in $update[0].payload.PSObject.Properties.Where({$_.Name -ne 'order'})) {
        if ((ConvertTo-Json -InputObject $create[0].payload.($field.Name) -Depth 64 -Compress) -cne (ConvertTo-Json -InputObject $field.Value -Depth 64 -Compress)) { throw "Create does not cover update field $($field.Name)" }
      }
    }
  }
  [pscustomobject]@{orders=$actual.Count;requests=$requests;payloads_match=$true;create_covers_update=$true} | Format-List
  . (Join-Path $PSScriptRoot 'Test-SqlEligibility.ps1')
  Test-SqlEligibility $connectionString $sql $fixture
}
finally {
  docker rm -f $container
  Remove-Item Env:MSSQL_SA_PASSWORD -ErrorAction SilentlyContinue
}
