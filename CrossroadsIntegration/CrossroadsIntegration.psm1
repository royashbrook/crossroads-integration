#requires -Version 7.5
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Delivery.ps1')
. (Join-Path $PSScriptRoot 'Adapters/TMW/TMW.ps1')

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

Export-ModuleMember -Function Get-CrossroadsSqlData,Get-CrossroadsTMWData,Receive-CrossroadsTMWData,Get-CrossroadsDeliverySummary,Initialize-CrossroadsDelivery,Get-CrossroadsDeliveryCursor,Set-CrossroadsDeliveryCursor,Add-CrossroadsDelivery,Send-CrossroadsDelivery
