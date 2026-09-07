#requires -Version 7.5
Set-StrictMode -Version Latest

Import-Module CrossroadsClient -MinimumVersion 1.0.3
. (Join-Path $PSScriptRoot 'Delivery.ps1')

function Read-CrossroadsSqlJson($reader) {
  if ($reader.FieldCount -ne 1) { throw 'SQL JSON query must return one column.' }
  $json = [Text.StringBuilder]::new()
  while ($reader.Read()) {
    if ($reader.IsDBNull(0)) { throw 'SQL JSON query returned a null chunk.' }
    $null = $json.Append($reader.GetString(0))
  }
  if ($reader.NextResult()) { throw 'SQL JSON query must return one result set.' }
  if ($json.Length -eq 0) { return }
  $json.ToString() | ConvertFrom-Json -Depth 64 -DateKind String -ErrorAction Stop
}

function Get-CrossroadsSqlData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string[]]$SqlFile,
    [string]$ConnectionString = $env:CONNECTION_STRING,
    [hashtable]$Parameters = @{},
    [int]$Timeout = 1800
  )
  $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
  $command = $connection.CreateCommand()
  $reader = $null
  try {
    $command.CommandText = (Get-Content $SqlFile -Raw -ErrorAction Stop) -join "`n"
    $command.CommandTimeout = $Timeout
    foreach ($entry in $Parameters.GetEnumerator()) {
      $value = if ($null -eq $entry.Value) { [DBNull]::Value } else { $entry.Value }
      $parameter = $command.Parameters.AddWithValue("@$($entry.Key)", $value)
      if ($value -is [string]) { $parameter.SqlDbType = [Data.SqlDbType]::VarChar }
    }
    $connection.Open()
    $reader = $command.ExecuteReader()
    Read-CrossroadsSqlJson $reader
  }
  finally {
    if ($reader) { $reader.Dispose() }
    $command.Dispose()
    $connection.Dispose()
  }
}

function Get-CrossroadsTMWData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$BillTo,
    [string]$Division,
    [Nullable[datetime]]$From,
    [Nullable[datetime]]$Through,
    [string]$ConnectionString = $env:CONNECTION_STRING,
    [string[]]$SqlFile = @(
      (Join-Path $PSScriptRoot 'Adapters/TMW/Get-Source.sql')
      (Join-Path $PSScriptRoot 'Adapters/TMW/Get-Requests.sql')
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
  $null = Initialize-CrossroadsDelivery $CacheDir
  $cursor = Get-CrossroadsDeliveryCursor $CacheDir
  if ($null -eq $From -and $null -ne $cursor) { $From = $cursor.AddMinutes(-5) }
  $source = @{ BillTo = $BillTo; Division = $Division; From = $From; Through = $Through; ConnectionString = $ConnectionString }
  if ($SqlFile) { $source.SqlFile = $SqlFile }
  $orders = @(Get-CrossroadsTMWData @source)
  $staged = @(Add-CrossroadsDelivery -Orders $orders -BaseUrl $BaseUrl -Tenant $Tenant -DestinationTenant $DestinationTenant -CacheDir $CacheDir -Persist $true)
  if ($orders.Count -gt 0) {
    $null = Set-CrossroadsDeliveryCursor -Current $cursor -Rows $orders -CacheDir $CacheDir
  }
  foreach ($item in $staged.Where({$_.data.kind -eq 'hold'})) {
    [pscustomobject]@{ order_number = $item.data.order_number; kind = 'hold'; http = $null; state = 'rejected'; status = 'held'; error = $item.data.response.message }
  }
}

Export-ModuleMember -Function Get-CrossroadsSqlData,Get-CrossroadsTMWData,Receive-CrossroadsTMWData,Get-CrossroadsDeliverySummary,Initialize-CrossroadsDelivery,Get-CrossroadsDeliveryCursor,Set-CrossroadsDeliveryCursor,Add-CrossroadsDelivery,Send-CrossroadsDelivery
