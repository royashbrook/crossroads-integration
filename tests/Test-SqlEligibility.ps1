function Test-SqlEligibility($connectionString, $sql, $fixture) {
  function Get-TestProjection($rows) {
    @(Get-CrossroadsSqlData -SqlFile $sql -ConnectionString $connectionString -Parameters @{Source=(ConvertTo-Json -InputObject @($rows) -Depth 12 -Compress)})
  }
  function Get-Body($order, $kind) {
    @($order.requests.Where({$_.kind -eq $kind}) | ForEach-Object { ConvertFrom-Json $_.payload_json -Depth 64 -DateKind String })
  }
  $row = $fixture[2] | Select-Object *
  $row | Add-Member tank_allocations @(@{tank_id='3';quantity=[double]$row.volume})
  $zero = $row | Select-Object *
  $zero.volume = '0'
  $zero.product_id = 'ZERO'
  $zero.updated_date = '2026-09-08T12:00:00'
  $result = (Get-TestProjection @($zero, $row))[0]
  $create = (Get-Body $result create)[0]
  if ($create.drops.Count -ne 1 -or $create.drops[0].product.source_id -eq 'ZERO') { throw 'Zero freight leaked into a mixed order.' }
  if ([datetime]$result.updated_date -ne [datetime]$zero.updated_date) { throw 'Excluded freight lost the source watermark.' }
  $result = (Get-TestProjection @($zero))[0]
  if ($result.requests.Count -or $result.hold -or [datetime]$result.updated_date -ne [datetime]$zero.updated_date) { throw 'Zero-only snapshot was lost or emitted work.' }

  $result = (Get-TestProjection @($row))[0]
  $drop = (Get-Body $result save_drop)[0]
  if ($drop.details[0].tank.tank_id -ne '3' -or [double]$drop.details[0].quantity -ne [double]$row.net_volume) { throw 'Single tank did not use its measured net quantity.' }
  $row.tank_allocations = @(@{tank_id='3';quantity=1000}, @{tank_id='8';quantity=2000})
  $row.net_volume = '3000'
  $result = (Get-TestProjection @($row))[0]
  $drop = (Get-Body $result save_drop)[0]
  if (($drop.details.tank.tank_id -join ',') -ne '3,8' -or ($drop.details.quantity -join ',') -ne '1000,2000') { throw 'Split tank quantities or identity changed.' }
  foreach ($case in 'no_tanks','unknown_tank','mismatched_split','missing_time','blank_time','zero_net') {
    $bad = $row | Select-Object *
    switch ($case) {
      no_tanks { $bad.tank_allocations = @() }
      unknown_tank { $bad.tank_allocations = @(@{tank_id=$null;quantity=3000}) }
      mismatched_split { $bad.net_volume = '2900' }
      missing_time { $bad.drop_depart = '' }
      blank_time { $bad.drop_depart = '   ' }
      zero_net { $bad.net_volume = '0' }
    }
    $result = (Get-TestProjection @($bad))[0]
    if ($result.requests.kind -contains 'save_drop' -or $result.requests.kind -contains 'status') { throw "Invalid drop became deliverable: $case" }
    if ($result.requests.kind -notcontains 'create') { throw "Invalid drop hid the valid create: $case" }
  }
  $bad = $row | Select-Object *
  $bad.product_id = 'SECOND'
  $bad.tank_allocations = @()
  $result = (Get-TestProjection @($row, $bad))[0]
  if ($result.requests.kind -contains 'save_drop') { throw 'Replace-mode drop silently omitted an invalid line at the same site.' }
  $assigned = $fixture[0] | Select-Object *
  $result = (Get-TestProjection @($assigned))[0]
  $status = (Get-Body $result status)[0]
  if ($status.delivery_eta -ne $assigned.delivery_eta -or $status.eta -ne $assigned.delivery_eta -or $null -ne $status.actual) { throw 'Assignment estimate missing or presented as an actual event.' }
  foreach ($eta in '', '   ', 'not-a-date') {
    $assigned.delivery_eta = $eta
    $result = (Get-TestProjection @($assigned))[0]
    if ($result.requests.kind -contains 'status' -or $result.requests.kind -notcontains 'create') { throw 'Invalid estimate was sent or hid its create.' }
  }
  'SQL eligibility cases passed.'
}
