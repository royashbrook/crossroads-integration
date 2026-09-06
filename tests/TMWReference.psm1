Set-StrictMode -Version Latest

function New-CrossroadsKey($source_id, $source_name, $product_source_id) {
  $key = [ordered]@{}
  foreach ($property in $PSBoundParameters.GetEnumerator()) {
    $value = "$($property.Value)".Trim()
    if ($value) { $key[$property.Key] = $value }
  }
  [pscustomobject]$key
}

function Get-MissingColumns($rows, $columns) {
  @($columns | Where-Object {
    $column = $_
    @($rows | Where-Object { [string]::IsNullOrWhiteSpace("$($_.$column)") }).Count
  })
}

function ConvertTo-CrossroadsNumber($value) {
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace("$value")) { return $null }
  [double]$value
}

function Get-LatestCrossroadsTime($rows, $column) {
  $dates = @($rows | ForEach-Object { $_.$column } | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
  if ($dates.Count -eq 0) { return $null }
  $dates | Sort-Object { [datetimeoffset]$_ } | Select-Object -Last 1
}

function Get-CrossroadsTMWProgress($rows) {
  $sourceStatus = "$($rows[0].source_status)".Trim().ToUpper()
  $liftDone = @($rows | Where-Object { "$($_.lift_status)".Trim().ToUpper() -ne 'DNE' }).Count -eq 0
  $dropDone = @($rows | Where-Object { "$($_.drop_status)".Trim().ToUpper() -ne 'DNE' }).Count -eq 0
  $someDropDone = @($rows | Where-Object { "$($_.drop_status)".Trim().ToUpper() -eq 'DNE' }).Count -gt 0

  if ($sourceStatus -eq 'CMP' -and $dropDone) {
    return [pscustomobject]@{ status = 'complete'; actual = Get-LatestCrossroadsTime $rows 'drop_depart' }
  }
  if ($someDropDone) {
    $completed = @($rows | Where-Object { "$($_.drop_status)".Trim().ToUpper() -eq 'DNE' })
    return [pscustomobject]@{ status = 'completed_drop'; actual = Get-LatestCrossroadsTime $completed 'drop_depart' }
  }
  if ($liftDone) {
    return [pscustomobject]@{ status = 'driving_to_drop'; actual = Get-LatestCrossroadsTime $rows 'lift_depart' }
  }
  $status = "$($rows[0].progress_status)".Trim()
  if ([string]::IsNullOrWhiteSpace($status)) { return $null }
  [pscustomobject]@{ status = $status; actual = $null }
}

function ConvertTo-CrossroadsOrder($rows) {
  foreach ($group in ($rows | Group-Object order_number)) {
    $lines = @($group.Group)
    $first = $lines[0]
    $missing = @(Get-MissingColumns $lines @('site_id', 'product_id', 'supplier_id', 'terminal_id', 'volume', 'window_start', 'window_end'))

    $drops = @(foreach ($dropGroup in ($lines | Group-Object { "$($_.site_id)|$($_.product_id)" })) {
      $drop = $dropGroup.Group[0]
      $volume = (@($dropGroup.Group | ForEach-Object { ConvertTo-CrossroadsNumber $_.volume }) | Measure-Object -Sum).Sum
      [pscustomobject][ordered]@{
        site = New-CrossroadsKey $drop.site_id $drop.site_name $drop.product_id
        product = New-CrossroadsKey $drop.product_id $drop.product_name
        volume = [int][math]::Round($volume)
        loads = @(foreach ($loadGroup in ($dropGroup.Group | Group-Object { "$($_.terminal_id)|$($_.product_id)|$($_.supplier_id)" })) {
          $load = $loadGroup.Group[0]
          [pscustomobject][ordered]@{
            terminals = @(New-CrossroadsKey $load.terminal_id $load.terminal_name)
            products = @(New-CrossroadsKey $load.product_id $load.product_name)
            suppliers = @(New-CrossroadsKey $load.supplier_id $load.supplier_name)
            price_types = @()
            contracts = @()
          }
        })
      }
    })

    $window = [pscustomobject][ordered]@{
      start = $first.window_start
      end = $first.window_end
      timezone = 'UTC'
    }
    $create = [pscustomobject][ordered]@{
      origin_order_number = "$($first.order_number)"
      delivery_window = $window
      drops = $drops
      units = 'gallons'
      created_by_hauler = $true
    }
    $order = [pscustomobject]@{ order_number = "$($first.order_number)" }
    $requests = [Collections.Generic.List[object]]::new()
    $progress = $null
    $invalidWindow = $missing.Count -eq 0 -and [datetimeoffset]$first.window_end -le [datetimeoffset]$first.window_start

    if ($missing.Count -eq 0 -and -not $invalidWindow) {
      $requests.Add([pscustomobject]@{ kind = 'create'; path = '/v1/order/create'; payload = $create })
      $requests.Add([pscustomobject]@{
        kind = 'update'
        path = '/v1/order/update'
        payload = [pscustomobject][ordered]@{ order = $order; delivery_window = $window; drops = $drops }
      })
    }

    $hold = if ($missing.Count -gt 0) {
      'missing ' + ($missing -join ', ')
    }
    elseif ($invalidWindow) {
      'delivery window end must be after start'
    }
    else {
      $null
    }
    if ("$($first.source_status)".Trim().ToUpper() -eq 'CAN') {
      $requests.Clear()
      $requests.Add([pscustomobject]@{
        kind = 'cancel'
        path = '/v1/order/cancel'
        payload = [pscustomobject][ordered]@{ order = $order; reason_code = 'CANCELLED IN TMS' }
      })
    }
    elseif ($missing.Count -eq 0 -and -not $invalidWindow) {
      $progress = Get-CrossroadsTMWProgress $lines
      if ($null -eq $progress) {
        $hold = "unmapped status $($first.source_status)"
      }
      elseif ($progress.status -eq 'complete') {
        $completionMissing = @(Get-MissingColumns $lines @('bol_number', 'bol_date', 'gross_volume', 'net_volume', 'drop_depart'))
        if ($completionMissing.Count -gt 0) {
          $hold = 'completion missing ' + ($completionMissing -join ', ')
        }
        else {
          foreach ($bolGroup in ($lines | Group-Object { "$($_.bol_number)|$($_.terminal_id)" })) {
            $bol = $bolGroup.Group[0]
            $requests.Add([pscustomobject]@{
              kind = 'save_bol'
              path = '/v1/order/save_bol'
              payload = [pscustomobject][ordered]@{
                order = $order
                bol_number = "$($bol.bol_number)".Trim()
                terminal = New-CrossroadsKey $bol.terminal_id $bol.terminal_name
                bol_date = $bol.bol_date
                details = @(foreach ($line in $bolGroup.Group) {
                  [pscustomobject][ordered]@{
                    site = New-CrossroadsKey $line.site_id $line.site_name $line.product_id
                    supplier = New-CrossroadsKey $line.supplier_id $line.supplier_name
                    product = New-CrossroadsKey $line.product_id $line.product_name
                    net_volume = ConvertTo-CrossroadsNumber $line.net_volume
                    gross_volume = ConvertTo-CrossroadsNumber $line.gross_volume
                  }
                })
              }
            })
          }
          foreach ($siteGroup in ($lines | Group-Object site_id)) {
            $site = $siteGroup.Group[0]
            $requests.Add([pscustomobject]@{
              kind = 'save_drop'
              path = '/v1/order/save_drop'
              payload = [pscustomobject][ordered]@{
                order = $order
                site = New-CrossroadsKey $site.site_id $site.site_name
                mode = 'replace'
                details = @(foreach ($line in $siteGroup.Group) {
                  [pscustomobject][ordered]@{
                    product = New-CrossroadsKey $line.product_id $line.product_name
                    quantity = ConvertTo-CrossroadsNumber $line.net_volume
                    post_drop_time = $line.drop_depart
                  }
                })
              }
            })
          }
          $requests.Add([pscustomobject]@{
            kind = 'status'
            path = '/v1/order/update_status'
            payload = [pscustomobject][ordered]@{ order = $order; progress_status = 'complete'; actual = $progress.actual }
          })
        }
      }
      else {
        $status = [ordered]@{
          order = $order
          progress_status = $progress.status
          delivery_eta = $first.delivery_eta
          actual = $progress.actual
        }
        if ($progress.status -in @('driving_to_drop', 'arrived_at_drop', 'dropping', 'completed_drop')) {
          $site = $lines | Where-Object { "$($_.drop_status)".Trim().ToUpper() -eq 'DNE' } |
            Sort-Object { [datetimeoffset]$_.drop_depart } | Select-Object -Last 1
          if ($null -eq $site) { $site = $first }
          $status.site = New-CrossroadsKey $site.site_id $site.site_name
        }
        else {
          $status.location = New-CrossroadsKey $first.terminal_id $first.terminal_name
        }
        $requests.Add([pscustomobject]@{
          kind = 'status'
          path = '/v1/order/update_status'
          payload = [pscustomobject]$status
        })
      }
    }

    [pscustomobject]@{
      order_number = "$($first.order_number)"
      updated_date = @($lines.updated_date | ForEach-Object { [datetime]$_ } | Sort-Object)[-1]
      progress = if ($null -ne $progress) { $progress.status } else { $null }
      hold = $hold
      requests = @($requests)
    }
  }
}

Export-ModuleMember -Function ConvertTo-CrossroadsOrder
