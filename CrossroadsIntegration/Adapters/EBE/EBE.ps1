function Get-CrossroadsEBEData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string[]]$SqlFile,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$ConnectionString,
    [hashtable]$Parameters = @{},
    [ValidateRange(1, 3600)][int]$Timeout = 60
  )
  foreach ($row in Get-CrossroadsSqlData -SqlFile $SqlFile -ConnectionString $ConnectionString -Parameters $Parameters -Timeout $Timeout) {
    if ("$($row.document_id)" -cnotmatch '^[1-9][0-9]*$') { throw 'Invalid EBE document ID.' }
    $row | Add-Member -NotePropertyMembers @{
      document_id = "$($row.document_id)"; order_number = "$($row.order_number)"
      bol_number = "$($row.bol_number)"; indexed_at = $row.indexed_at
      file_name = "EBE-$($row.document_id).pdf"
    } -Force
    $row
  }
}

# The portal login and PDF fetch live in the ShipsDocuments module; these keep the adapter's
# names and parameters so document consumers do not change.
function New-CrossroadsEBESession {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$BaseUrl,
    [Parameter(Mandatory)][pscredential]$Credential,
    [ValidateRange(1, 3600)][int]$TimeoutSec = 20
  )
  New-ShipsSession -BaseUrl $BaseUrl -Credential $Credential -TimeoutSec $TimeoutSec
}

function Read-CrossroadsEBEDocument {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$DocumentId,
    [Parameter(Mandatory)]$Session,
    [ValidateRange(1, 3600)][int]$TimeoutSec = 20
  )
  ,(Get-ShipsDocument -DocumentId $DocumentId -Session $Session -TimeoutSec $TimeoutSec)
}
