function Get-CrossroadsTMWData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$BillTo,
    [string]$Division,
    [Nullable[datetime]]$From,
    [Nullable[datetime]]$Through,
    [string]$ConnectionString = $env:CONNECTION_STRING,
    [string[]]$SqlFile = @(
      (Join-Path $PSScriptRoot 'Get-Source.sql')
      (Join-Path $PSScriptRoot 'Get-Requests.sql')
    )
  )
  if ($null -ne $From -and $null -ne $Through -and $Through -le $From) { throw 'Through must be after From.' }
  $parameters = @{ BillTo = $BillTo; Division = if ($Division) { $Division } else { $null }; From = $From; Through = $Through }
  foreach ($order in @(Get-CrossroadsSqlData -SqlFile $SqlFile -ConnectionString $ConnectionString -Parameters $parameters)) {
    foreach ($request in $order.requests) {
      $request.payload_json = ConvertTo-CompactJson $request.payload_json
    }
    $order
  }
}

function Receive-CrossroadsTMWData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$BillTo,
    [string]$Division,
    [Parameter(Mandatory)] [ValidateNotNullOrWhiteSpace()] [string]$BaseUrl,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Tenant,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$DestinationTenant,
    [Nullable[datetime]]$From,
    [Nullable[datetime]]$Through,
    [string]$ConnectionString = $env:CONNECTION_STRING,
    [string[]]$SqlFile,
    [string]$CacheDir = (Join-Path $PWD 'cache')
  )
  $index = Initialize-Delivery $CacheDir
  $cursor = Get-CrossroadsDeliveryCursor $CacheDir
  if ($null -eq $From -and $null -ne $cursor) { $From = $cursor.AddMinutes(-5) }
  $source = @{ BillTo = $BillTo; Division = $Division; From = $From; Through = $Through; ConnectionString = $ConnectionString }
  if ($SqlFile) { $source.SqlFile = $SqlFile }
  $orders = @(Get-CrossroadsTMWData @source)
  $staged = @(Add-Delivery $orders $BaseUrl $CacheDir $true $Tenant $DestinationTenant $index)
  if ($orders.Count -gt 0) {
    $null = Set-CrossroadsDeliveryCursor -Current $cursor -Rows $orders -CacheDir $CacheDir
  }
  foreach ($item in $staged.Where({$_.data.kind -eq 'hold'})) {
    [pscustomobject]@{ order_number = $item.data.order_number; kind = 'hold'; http = $null; state = 'rejected'; status = 'held'; error = $item.data.response.message }
  }
}
