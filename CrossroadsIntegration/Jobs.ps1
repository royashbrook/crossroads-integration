# Feed entry points: a feed's job.ps1 imports the module and calls one of these with its settings.json.
# Each runs in the settings file's folder, so the log, cache and state land there.

# "env:NAME" anywhere in the settings is read from that environment variable, so secrets stay out of the file
function Resolve-CrossroadsEnvValue($Value) {
  if ($Value -is [string]) {
    if ($Value -match '^env:(.+)$') { return [Environment]::GetEnvironmentVariable($Matches[1]) }
    return $Value
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = @{}
    foreach ($key in $Value.Keys) { $copy[$key] = Resolve-CrossroadsEnvValue $Value[$key] }
    return $copy
  }
  if ($Value -is [System.Collections.IList]) { return , @(foreach ($item in $Value) { Resolve-CrossroadsEnvValue $item }) }
  $Value
}

function Read-CrossroadsSettings([string]$Path) {
  $full = (Resolve-Path -LiteralPath $Path).Path
  $settings = Resolve-CrossroadsEnvValue (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json -AsHashtable)
  $settings.directory = Split-Path $full
  # the module runs under strict mode, where reading an absent key throws; optional ones read as null
  foreach ($name in 'cache', 'origin_instance', 'keepdays', 'purgefiles', 'dry_run', 'max_uploads', 'max_documents',
    'budget_seconds', 'keep_days', 'prior_attempts', 'read_legacy_state', 'scope', 'ebe', 'state') {
    if (-not $settings.ContainsKey($name)) { $settings[$name] = $null }
  }
  $settings
}

# an unset env: value resolves to nothing; name it before anything runs
function Assert-CrossroadsSettings([hashtable]$Settings, [string[]]$Names) {
  foreach ($name in $Names) {
    $value = $Settings
    foreach ($part in $name -split '\.') { $value = if ($value -is [System.Collections.IDictionary]) { $value[$part] } }
    if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "Required configuration absent: $name" }
  }
}

function Clear-CrossroadsFeed([hashtable]$Settings) {
  if (-not $Settings.keepdays) { return }
  l 'Cleanup'; Clear-Files @{ keepdays = $Settings.keepdays; purgefiles = $Settings.purgefiles }
}

# TMW orders to Crossroads: one cache (cursor and proofs) per bill-to, so a newer customer never skips an older one's changes
function Invoke-CrossroadsOrders {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$Settings)
  $s = Read-CrossroadsSettings $Settings
  Assert-CrossroadsSettings $s 'base_url', 'tenant', 'destination_tenant', 'division', 'billtos', 'client_id', 'client_secret', 'connection_string'
  $version = $MyInvocation.MyCommand.Module.Version
  Push-Location $s.directory
  try {
    & {
      $ErrorActionPreference = 'Stop'
      $route = @{ BaseUrl = $s.base_url; Tenant = $s.tenant; DestinationTenant = $s.destination_tenant }
      $cache = if ($s.cache) { [string]$s.cache } else { 'cache/{0}' }
      "`n`n"
      l 'Start'; "Crossroads: {0}" -f $s.base_url
      "CrossroadsIntegration: {0}" -f $version
      Clear-CrossroadsFeed $s
      foreach ($billTo in @($s.billtos)) {
        $cacheDir = Join-Path $s.directory ($cache -f $billTo)
        l "Get Data: $billTo"
        $results = @(Receive-CrossroadsTMWData -BillTo $billTo -Division $s.division -ConnectionString $s.connection_string -CacheDir $cacheDir @route)
        l 'Use Data'
        $send = @{ ClientId = $s.client_id; ClientSecret = $s.client_secret; CacheDir = $cacheDir }
        if ($s.origin_instance) { $send.OriginInstance = $s.origin_instance }
        $results += @(Send-CrossroadsDelivery @send @route)
        l 'Show Results'
        $results | Group-Object kind, http, state, status, error | ForEach-Object {
          $_.Name
          $_.Group | Select-Object order_number | Format-Table | Out-String -Width 4096
        }
        Get-CrossroadsDeliverySummary $cacheDir | Format-List | Out-String -Width 4096
      }
      l 'End'
    } *>&1 | Tee-Object -Append ('{0:yyyyMMdd}.log' -f (Get-Date))
  } finally {
    Pop-Location
  }
}

# one document run's settings and EBE session, for the callbacks Send-CrossroadsDocuments makes
$script:DocumentRun = $null

function Assert-CrossroadsDocumentScope($Document) {
  $scope = $script:DocumentRun.scope
  if ($Document.billto -cnotin @($scope.billtos) -or $Document.division -cne $scope.division -or
      "$($Document.document_id)" -notmatch '^[1-9][0-9]*$' -or
      "$($Document.order_number)" -notmatch '^[1-9][0-9]*$' -or
      [string]::IsNullOrWhiteSpace($Document.bol_number) -or $Document.bol_number.Trim() -ieq 'undefined') {
    throw "BOL document identity or $(@($scope.billtos) -join ', ') / $($scope.division) scope is invalid."
  }
}

function Read-CrossroadsDocumentPdf($Document) {
  $run = $script:DocumentRun
  if (-not $run.session) {
    $credential = [pscredential]::new($run.ebe.username, [Net.NetworkCredential]::new('', $run.ebe.password).SecurePassword)
    $run.session = New-CrossroadsEBESession -BaseUrl $run.ebe.base_url -Credential $credential
  }
  Read-CrossroadsEBEDocument -Session $run.session -DocumentId $Document.document_id
}

# delivery state is written to the repo as it happens, so a run that dies midway still leaves its record
function Get-CrossroadsStateSha([string]$Path) {
  $run = $script:DocumentRun
  if ($run.shas.ContainsKey($Path)) { return $run.shas[$Path] }
  # Git's checkout filters may change line endings; use the stored blob, not a rehash.
  $sha = git -C $run.directory rev-parse "HEAD:$Path"
  if ($LASTEXITCODE -ne 0 -or $sha -cnotmatch '^[a-f0-9]{40}$') { throw 'State identity unavailable.' }
  $sha
}

function Invoke-CrossroadsStateRequest([string]$Method, [string]$Path, [hashtable]$Body) {
  $state = $script:DocumentRun.state
  Invoke-WebRequest -Uri "https://api.github.com/repos/$($state.repository)/contents/$Path" `
    -Method $Method -Headers @{ Authorization = "Bearer $($state.token)"; Accept = 'application/vnd.github+json' } `
    -ContentType 'application/json' -Body ($Body | ConvertTo-Json) -TimeoutSec 20 -SkipHttpErrorCheck
}

function Write-CrossroadsDocumentState([string]$Path, [string]$Json, [bool]$CreateOnly) {
  $run = $script:DocumentRun
  $body = @{ message = "retain document delivery state (refs #$($run.state.issue))"; branch = 'main'
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json)) }
  if (-not $CreateOnly -and (Test-Path -LiteralPath (Join-Path $run.directory $Path))) {
    $body.sha = Get-CrossroadsStateSha $Path
  }
  $response = Invoke-CrossroadsStateRequest Put $Path $body
  if ($CreateOnly -and $response.StatusCode -in 409, 422) { return $false }
  $expected = if ($body.ContainsKey('sha')) { 200 } else { 201 }
  if ($response.StatusCode -ne $expected) { throw "State write returned HTTP $($response.StatusCode): $Path" }
  $sha = ($response.Content | ConvertFrom-Json).content.sha
  if ($sha -isnot [string] -or $sha -cnotmatch '^[a-f0-9]{40}$') { throw 'State write returned no valid blob identity.' }
  $run.shas[$Path] = $sha
  $true
}

function Remove-CrossroadsDocumentState([string]$Path, [string]$ExistingJson) {
  $run = $script:DocumentRun
  if ((Get-Content -LiteralPath (Join-Path $run.directory $Path) -Raw) -cne $ExistingJson) { throw 'State changed before removal.' }
  $body = @{ message = "retire document delivery state (refs #$($run.state.issue))"; branch = 'main'; sha = (Get-CrossroadsStateSha $Path) }
  $response = Invoke-CrossroadsStateRequest Delete $Path $body
  if ($response.StatusCode -ne 200) { throw "State removal returned HTTP $($response.StatusCode): $Path" }
  $run.shas.Remove($Path)
}

# BOL documents from EBE to Crossroads, each once, within the run's time budget
function Invoke-CrossroadsDocuments {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$Settings)
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $s = Read-CrossroadsSettings $Settings
  $version = $MyInvocation.MyCommand.Module.Version
  Push-Location $s.directory
  try {
    & {
      "`n`n"
      l 'Start'; "Crossroads: {0}" -f $s.base_url
      "CrossroadsIntegration: {0}" -f $version
      Clear-CrossroadsFeed $s
      l 'Use Data'
      Send-CrossroadsDocumentRun $s $clock $version
      l 'End'
    } *>&1 | Tee-Object -Append ('{0:yyyyMMdd}.log' -f (Get-Date))
  } finally {
    Pop-Location
  }
}

function Send-CrossroadsDocumentRun([hashtable]$s, [Diagnostics.Stopwatch]$clock, $version) {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  $apply = -not $s.dry_run
  $required = @('base_url', 'tenant', 'destination_tenant', 'destination_instance', 'scope.billtos', 'scope.division', 'client_id', 'client_secret', 'connection_string')
  if ($apply) { $required += 'ebe.base_url', 'ebe.username', 'ebe.password', 'state.repository', 'state.token', 'state.issue' }
  Assert-CrossroadsSettings $s $required
  $maxDocuments = if ($s.max_documents) { [int]$s.max_documents } else { 2000 }
  $script:DocumentRun = @{ directory = $s.directory; scope = $s.scope; ebe = $s.ebe; state = $s.state; session = $null; shas = @{} }
  $results = [Collections.Generic.List[object]]::new()
  $report = [ordered]@{ apply = $apply; upload_attempts = 0; checked_at = [datetime]::UtcNow.ToString('o') }
  $candidateKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $out = (New-Item -ItemType Directory -Force (Join-Path $s.directory 'out')).FullName
  $token = $null
  try {
    $report.modules = @{ client = "$((Get-Module CrossroadsClient).Version)"; integration = "$version" }
    $documents = @(Get-CrossroadsEBEData -ConnectionString $s.connection_string -Timeout 60 `
      -SqlFile (Join-Path $s.directory 'get-data.sql'), (Join-Path $PSScriptRoot 'Adapters/EBE/as-json.sql'))
    $report.source_rows = $documents.Count
    if ($documents.Count -gt $maxDocuments) { throw 'Source selection truncated. No uploads.' }
    foreach ($document in $documents) { Assert-CrossroadsDocumentScope $document }
    $documents = @($documents | Group-Object -CaseSensitive order_number, bol_number | ForEach-Object { $_.Group[0] })
    foreach ($document in $documents) { $null = $candidateKeys.Add("$($document.order_number)/$($document.bol_number)") }
    $report.bol_candidates = $documents.Count
    $prior = if ($s.prior_attempts) {
      @(Get-ChildItem (Join-Path $s.directory "$($s.prior_attempts)/*.json") -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    } else { @() }
    $token = Get-CrossroadsToken -BaseUrl $s.base_url -TokenPath '/auth/token' -ClientId $s.client_id `
      -ClientSecret $s.client_secret -GrantType password -TimeoutSec 15
    $budget = if ($s.budget_seconds) { [int]$s.budget_seconds } else { 480 }
    $remaining = $budget - [int][Math]::Ceiling($clock.Elapsed.TotalSeconds)
    if ($remaining -gt 0) {
      $send = @{
        Documents = $documents; BaseUrl = $s.base_url; Token = $token
        Tenant = $s.tenant; DestinationTenant = $s.destination_tenant; DestinationInstance = $s.destination_instance
        StateDirectory = $s.directory; PriorAttempts = $prior; KeepDays = $(if ($s.keep_days) { [int]$s.keep_days } else { 14 })
        ReadDocument = ${function:Read-CrossroadsDocumentPdf}
        WriteState = ${function:Write-CrossroadsDocumentState}; RemoveState = ${function:Remove-CrossroadsDocumentState}
        BudgetSeconds = $remaining; MaxDocuments = $maxDocuments; MaxUploads = [int]$s.max_uploads
        ReadLegacyState = [bool]$s.read_legacy_state; Apply = $apply
      }
      Send-CrossroadsDocuments @send | ForEach-Object { $results.Add($_) }
    }
  } finally {
    $token = $null; $script:DocumentRun = $null
    $report.upload_attempts = [int](@($results | ForEach-Object { [int]$_.upload_attempts }) | Measure-Object -Sum).Sum
    $report.documents_checked = @($results | Where-Object { $candidateKeys.Contains("$($_.order_number)/$($_.bol_number)") } |
      Group-Object -CaseSensitive order_number, bol_number).Count
    if ($report.Contains('bol_candidates')) {
      $report.remaining_this_run = [Math]::Max(0, $report.bol_candidates - $report.documents_checked)
    }
    $report.elapsed_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
    $report.results = @($results)
    $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out 'delivery.json')
    $results | Group-Object disposition | Select-Object Name, Count | Format-Table | Out-String -Width 4096
  }
}
