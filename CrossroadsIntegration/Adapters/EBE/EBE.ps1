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
    [pscustomobject]@{
      document_id = "$($row.document_id)"; order_number = "$($row.order_number)"
      bol_number = "$($row.bol_number)"; indexed_at = $row.indexed_at
      file_name = "EBE-$($row.document_id).pdf"
    }
  }
}

function New-CrossroadsEBESession {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$BaseUrl,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$Username,
    [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$Password,
    [ValidateRange(1, 3600)][int]$TimeoutSec = 20
  )
  $uri = $BaseUrl.TrimEnd('/') + '/'
  $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
  $login = Invoke-WebRequest -Uri $uri -WebSession $session -TimeoutSec $TimeoutSec -ErrorAction Stop
  $form = @{ UN = $Username; PW = $Password; btnlogin = 'Log In' }
  foreach ($name in '__VIEWSTATE', '__VIEWSTATEGENERATOR', '__EVENTVALIDATION') {
    $match = [regex]::Match($login.Content,
      '<input[^>]*name=["'']' + $name + '["''][^>]*value=["'']([^"'']*)["'']', 'IgnoreCase')
    if ($match.Success) { $form[$name] = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) }
  }
  $response = Invoke-WebRequest -Uri $uri -Method Post -Body $form -WebSession $session -TimeoutSec $TimeoutSec -ErrorAction Stop
  if ($response.Content -match 'name=["'']UN["'']' -and $response.Content -match 'name=["'']PW["'']') {
    throw 'EBE reader authentication failed.'
  }
  [pscustomobject]@{ BaseUrl = $uri; Session = $session }
}

function Read-CrossroadsEBEDocument {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$DocumentId,
    [Parameter(Mandatory)]$Session,
    [ValidateRange(1, 3600)][int]$TimeoutSec = 20
  )
  $uri = $Session.BaseUrl + "Pages/convertFile.aspx?multiProc=True&doc_id=$DocumentId"
  $response = Invoke-WebRequest -Uri $uri -WebSession $Session.Session -TimeoutSec $TimeoutSec -ErrorAction Stop
  $memory = [IO.MemoryStream]::new()
  try {
    if ($response.RawContentStream.CanSeek) { $response.RawContentStream.Position = 0 }
    $response.RawContentStream.CopyTo($memory)
    [byte[]]$bytes = $memory.ToArray()
    if ($bytes.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 5) -cne '%PDF-') { throw 'EBE returned non-PDF content.' }
    return ,$bytes
  } finally { $memory.Dispose() }
}
