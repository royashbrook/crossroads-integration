BeforeAll {
  $root = Join-Path $PSScriptRoot '../CrossroadsIntegration'
  $module = Import-Module (Join-Path $root 'CrossroadsIntegration.psd1') -Force -PassThru
}

Describe 'Public package' {
  It 'imports in a fresh process using only manifest-listed files' {
    $manifest = Import-PowerShellDataFile (Join-Path $root 'CrossroadsIntegration.psd1')
    $package = Join-Path $TestDrive 'CrossroadsIntegration'
    foreach ($file in $manifest.FileList) {
      $target = Join-Path $package $file
      $null = New-Item -ItemType Directory (Split-Path $target) -Force
      Copy-Item (Join-Path $root $file) $target
    }
    @(Get-ChildItem $root -Recurse -File).Count | Should -Be $manifest.FileList.Count
    $script = Join-Path $TestDrive 'import.ps1'
    Set-Content $script {
      param($Path)
      $ErrorActionPreference = 'Stop'
      $module = Import-Module $Path -Force -PassThru
      if ($module.ExportedFunctions.Count -ne 9) { throw 'Unexpected exports.' }
      $sql = & $module {
        Set-Item Function:script:Get-CrossroadsSqlData { param($SqlFile) [pscustomobject]@{ sql = $SqlFile; requests = @() } }
        (Get-CrossroadsTMWData -BillTo ACCOUNT -From '2026-01-01' -Through '2026-01-02').sql
      }
      foreach ($file in $sql) {
        if (-not (Test-Path $file) -or -not $file.StartsWith($module.ModuleBase)) { throw 'SQL outside package.' }
      }
      'Package import passed.'
    }.ToString()
    $output = & (Get-Process -Id $PID).Path -NoProfile -File $script (Join-Path $package 'CrossroadsIntegration.psd1') 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    $output | Should -Contain 'Package import passed.'
  }

  It 'compacts numeric JSON at the source boundary without changing its shape' {
    $script:raw = '[{"volume":7900,"quantity":7900.0000000000000000,"fraction":100.1000000000000000,"id":"001","date":"2026-01-01T00:00:00Z","items":[],"enabled":true,"missing":null}]'
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ requests = @([pscustomobject]@{ payload_json = $script:raw }) }
    }
    $order = Get-CrossroadsTMWData -BillTo ACCOUNT -From '2026-01-01' -Through '2026-01-02'
    $order.requests[0].payload_json | Should -BeExactly '[{"volume":7900,"quantity":7900.0,"fraction":100.1,"id":"001","date":"2026-01-01T00:00:00Z","items":[],"enabled":true,"missing":null}]'
  }

  It 'passes source configuration as SQL parameters' {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration { }
    $null = Get-CrossroadsTMWData -BillTo "ACCOUNT'QUOTED" -Division DIVISION -From '2026-01-01' -Through '2026-01-02' -SqlFile custom.sql -ConnectionString test
    Should -Invoke Get-CrossroadsSqlData -ModuleName CrossroadsIntegration -Exactly -Times 1 -ParameterFilter {
      $Parameters.BillTo -ceq "ACCOUNT'QUOTED" -and $Parameters.Division -ceq 'DIVISION' -and $SqlFile -eq 'custom.sql' -and $ConnectionString -eq 'test'
    }
  }

  It 'reassembles split SQL JSON before parsing and retains date strings' {
    $table = [Data.DataTable]::new()
    $null = $table.Columns.Add('json', [string])
    $null = $table.Rows.Add('[{"requests":[],"date":"2026-01-01')
    $null = $table.Rows.Add('T00:00:00Z"}]')
    $reader = $table.CreateDataReader()
    try {
      $rows = @(& $module { param($r) Read-CrossroadsSqlJson $r } $reader)
      $rows.Count | Should -Be 1
      $rows[0].date | Should -BeExactly '2026-01-01T00:00:00Z'
      $rows[0].requests.Count | Should -Be 0
    }
    finally { $reader.Dispose(); $table.Dispose() }
  }
}
