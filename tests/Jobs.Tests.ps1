BeforeAll {
  Import-Module "$PSScriptRoot/../CrossroadsIntegration/CrossroadsIntegration.psd1" -Force
  $env:XRJ_SECRET = 'from-env-secret'; $env:XRJ_CONN = 'Server=example;'; $env:XRJ_PASSWORD = 'from-env-password'
  $env:XRJ_REPO = 'owner/feed'; $env:XRJ_TOKEN = 'gh-token'
  function Set-Settings([string]$Dir, [hashtable]$Settings) {
    $null = New-Item -ItemType Directory -Force $Dir
    $Settings | ConvertTo-Json -Depth 8 | Set-Content "$Dir/settings.json"
    "$Dir/settings.json"
  }
  function Get-Log([string]$Dir) { Get-Content (Join-Path $Dir ('{0:yyyyMMdd}.log' -f (Get-Date))) | ForEach-Object { ($_ -split "`t")[-1] } }
}

Describe 'Invoke-CrossroadsOrders' {
  BeforeEach {
    $dir = Join-Path $TestDrive "orders-$([guid]::NewGuid())"
    $base = @{
      keepdays = 10; purgefiles = '*.log'
      base_url = 'https://crossroads.example/api'; tenant = 'ORIGIN'; destination_tenant = 'DEST'
      division = 'DIV'; billtos = @('AAA', 'BBB')
      client_id = 'id'; client_secret = 'env:XRJ_SECRET'; connection_string = 'env:XRJ_CONN'
    }
    Mock Receive-CrossroadsTMWData -ModuleName CrossroadsIntegration { [pscustomobject]@{ kind = 'request'; order_number = 1 } }
    Mock Send-CrossroadsDelivery -ModuleName CrossroadsIntegration { }
    Mock Get-CrossroadsDeliverySummary -ModuleName CrossroadsIntegration { [pscustomobject]@{ pending = 0 } }
    Mock Clear-Files -ModuleName CrossroadsIntegration { }
  }

  It 'runs each bill-to with its own cache, from the settings folder, and logs the run' {
    $path = Set-Settings $dir $base
    Invoke-CrossroadsOrders $path | Out-Null
    foreach ($expected in 'AAA', 'BBB') {
      Should -Invoke Receive-CrossroadsTMWData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
        $BillTo -eq $expected -and $Division -eq 'DIV' -and $ConnectionString -eq 'Server=example;' -and
        $CacheDir -eq (Join-Path $dir "cache/$expected") -and $Tenant -eq 'ORIGIN' -and $DestinationTenant -eq 'DEST'
      }
      Should -Invoke Send-CrossroadsDelivery -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
        $cacheDir -eq (Join-Path $dir "cache/$expected") -and $clientSecret -eq 'from-env-secret' -and -not $OriginInstance
      }
    }
    Should -Invoke Clear-Files -ModuleName CrossroadsIntegration -Times 1 -Exactly
    $log = Get-Log $dir
    $log | Should -Contain 'Start'
    $log | Should -Contain 'Get Data'
    $log | Should -Contain 'BBB'
    $log | Should -Contain 'End'
    Get-Content "$dir/settings.json" -Raw | Should -Not -Match 'from-env'
  }

  It 'keeps a single cache when the settings name one, and passes the origin instance when set' {
    $path = Set-Settings $dir ($base + @{ cache = 'cache'; origin_instance = 'TMW' })
    Invoke-CrossroadsOrders $path | Out-Null
    Should -Invoke Receive-CrossroadsTMWData -ModuleName CrossroadsIntegration -Times 2 -Exactly -ParameterFilter { $CacheDir -eq (Join-Path $dir 'cache') }
    Should -Invoke Send-CrossroadsDelivery -ModuleName CrossroadsIntegration -Times 2 -Exactly -ParameterFilter { $OriginInstance -eq 'TMW' }
  }

  It 'names a missing secret before anything runs' {
    $base.client_secret = 'env:XRJ_UNSET'
    $path = Set-Settings $dir $base
    { Invoke-CrossroadsOrders $path } | Should -Throw 'Required configuration absent: client_secret'
    Should -Invoke Receive-CrossroadsTMWData -ModuleName CrossroadsIntegration -Times 0
  }
}

Describe 'Invoke-CrossroadsDocuments' {
  BeforeEach {
    $dir = Join-Path $TestDrive "docs-$([guid]::NewGuid())"
    $base = @{
      keepdays = 10; purgefiles = '*.log'
      base_url = 'https://crossroads.example/api'; tenant = 'ORIGIN'; destination_tenant = 'DEST'; destination_instance = 'INST'
      client_id = 'id'; client_secret = 'env:XRJ_SECRET'; connection_string = 'env:XRJ_CONN'
      scope = @{ billtos = @('AAA'); division = 'DIV' }
      ebe = @{ base_url = 'https://portal.example/'; username = 'reader'; password = 'env:XRJ_PASSWORD' }
      state = @{ repository = 'env:XRJ_REPO'; token = 'env:XRJ_TOKEN'; issue = 7 }
      max_uploads = 0; max_documents = 2000
    }
    $global:XrjDocs = @(
      [pscustomobject]@{ billto = 'AAA'; division = 'DIV'; document_id = 11; order_number = 101; bol_number = 'B1' }
      [pscustomobject]@{ billto = 'AAA'; division = 'DIV'; document_id = 12; order_number = 102; bol_number = 'B2' }
    )
    $global:XrjSend = $null
    Mock Get-CrossroadsEBEData -ModuleName CrossroadsIntegration { $global:XrjDocs }
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'token' }
    Mock Clear-Files -ModuleName CrossroadsIntegration { }
    Mock Send-CrossroadsDocuments -ModuleName CrossroadsIntegration {
      $global:XrjSend = @{ Apply = [bool]$Apply; MaxUploads = $MaxUploads; MaxDocuments = $MaxDocuments; KeepDays = $KeepDays
        DestinationInstance = $DestinationInstance; StateDirectory = $StateDirectory; ReadLegacyState = [bool]$ReadLegacyState
        PriorAttempts = @($PriorAttempts); PriorAttemptsIsNull = ($null -eq $PriorAttempts) }
      $pdfs = @(foreach ($document in $Documents) { & $ReadDocument $document })
      $global:XrjSend.pdfs = $pdfs
      $global:XrjSend.wrote = & $WriteState 'state/101.json' '{"a":1}' $true
      [pscustomobject]@{ order_number = 101; bol_number = 'B1'; disposition = 'uploaded'; upload_attempts = 1 }
    }
    Mock New-CrossroadsEBESession -ModuleName CrossroadsIntegration { [pscustomobject]@{ user = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } }
    Mock Read-CrossroadsEBEDocument -ModuleName CrossroadsIntegration { "pdf-$DocumentId" }
    Mock Invoke-WebRequest -ModuleName CrossroadsIntegration {
      $global:XrjWrite = @{ uri = $Uri; method = $Method; auth = $Headers.Authorization; body = $Body | ConvertFrom-Json }
      [pscustomobject]@{ StatusCode = 201; Content = '{"content":{"sha":"0123456789abcdef0123456789abcdef01234567"}}' }
    }
  }

  It 'delivers with the settings, one EBE login per run, and writes state through the repo' {
    $path = Set-Settings $dir $base
    Invoke-CrossroadsDocuments $path | Out-Null
    $send = $global:XrjSend
    $send.Apply | Should -BeTrue
    $send.MaxUploads | Should -Be 0
    $send.MaxDocuments | Should -Be 2000
    $send.KeepDays | Should -Be 14
    $send.DestinationInstance | Should -Be 'INST'
    $send.StateDirectory | Should -Be $dir
    $send.ReadLegacyState | Should -BeFalse
    $send.pdfs | Should -Be @('pdf-11', 'pdf-12')
    Should -Invoke New-CrossroadsEBESession -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $BaseUrl -eq 'https://portal.example/' -and $Credential.UserName -eq 'reader' -and $Credential.GetNetworkCredential().Password -eq 'from-env-password'
    }
    Should -Invoke Get-CrossroadsEBEData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $ConnectionString -eq 'Server=example;' -and $SqlFile[0] -eq (Join-Path $dir 'get-data.sql') -and (Test-Path $SqlFile[1])
    }
    $send.wrote | Should -BeTrue
    $global:XrjWrite.uri | Should -Be 'https://api.github.com/repos/owner/feed/contents/state/101.json'
    $global:XrjWrite.auth | Should -Be 'Bearer gh-token'
    $global:XrjWrite.body.message | Should -Be 'retain document delivery state (refs #7)'
    $report = Get-Content "$dir/out/delivery.json" -Raw | ConvertFrom-Json
    $report.upload_attempts | Should -Be 1
    $report.bol_candidates | Should -Be 2
    (Get-Log $dir) | Should -Contain 'End'
  }

  It 'refuses a document outside its scope before any upload' {
    $global:XrjDocs[1].billto = 'ZZZ'
    $path = Set-Settings $dir $base
    { Invoke-CrossroadsDocuments $path } | Should -Throw '*AAA / DIV scope is invalid*'
    Should -Invoke Send-CrossroadsDocuments -ModuleName CrossroadsIntegration -Times 0
  }

  It 'loads prior attempts and legacy state only when the settings ask' {
    $null = New-Item -ItemType Directory -Force "$dir/probes/attempts"
    '{"order_number":"101","bol_number":"B1","document_id":"11"}' | Set-Content "$dir/probes/attempts/11.json"
    $path = Set-Settings $dir ($base + @{ prior_attempts = 'probes/attempts'; read_legacy_state = $true })
    Invoke-CrossroadsDocuments $path | Out-Null
    $global:XrjSend.PriorAttempts.Count | Should -Be 1
    $global:XrjSend.ReadLegacyState | Should -BeTrue
  }

  # an empty array coming out of an if/else unrolls to $null. Send's foreach skips $null, but its
  # `$PriorAttempts | Where-Object` runs once with $_ = $null and strict mode throws on the first
  # ready document of a feed that has no prior_attempts setting.
  It 'hands Send an empty array, not null, when no prior attempts are configured or found' {
    $path = Set-Settings $dir $base
    Invoke-CrossroadsDocuments $path | Out-Null
    $global:XrjSend.PriorAttemptsIsNull | Should -BeFalse

    $null = New-Item -ItemType Directory -Force "$dir/probes/empty"
    $path = Set-Settings $dir ($base + @{ prior_attempts = 'probes/empty' })
    Invoke-CrossroadsDocuments $path | Out-Null
    $global:XrjSend.PriorAttemptsIsNull | Should -BeFalse
  }

  It 'dry_run plans without the EBE login or state settings' {
    $settings = $base.Clone(); $settings.Remove('ebe'); $settings.Remove('state'); $settings.dry_run = $true
    $path = Set-Settings $dir $settings
    Mock Send-CrossroadsDocuments -ModuleName CrossroadsIntegration { $global:XrjSend = @{ Apply = [bool]$Apply } }
    Invoke-CrossroadsDocuments $path | Out-Null
    $global:XrjSend.Apply | Should -BeFalse
  }
}
