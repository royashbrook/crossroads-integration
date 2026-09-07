BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
}

Describe 'Delivery summary' {
  BeforeEach {
    $cache = Join-Path $TestDrive ([guid]::NewGuid().ToString())
  }

  It 'returns an empty summary without creating a missing directory' {
    $summary = Get-CrossroadsDeliverySummary $cache
    $summary.Pending | Should -Be 0
    $summary.Rejected | Should -Be 0
    $summary.Reconciled | Should -Be 0
    $summary.Sent | Should -Be 0
    $summary.TotalFiles | Should -Be 0
    $summary.SizeMB | Should -Be 0
    $summary.OldestPendingSourceUpdate | Should -BeNullOrEmpty
    $summary.Cursor | Should -BeNullOrEmpty
    Test-Path $cache | Should -BeFalse
  }

  It 'counts request states and bytes without reading or modifying payloads' {
    $null = New-Item -ItemType Directory $cache
    $hash = 'a' * 64
    foreach ($state in 'X00', 'X40', 'X80', 'X90') {
      [IO.File]::WriteAllBytes((Join-Path $cache "20260102T030405000.ORDER.S10.R20.$state.$hash.json"), [byte[]]::new(262144))
    }
    $null = New-Item -ItemType File (Join-Path $cache '.gitkeep')
    $before = @(Get-ChildItem $cache -File | Get-FileHash).Hash
    Mock Get-Content -ModuleName CrossroadsIntegration { throw 'Do not read payloads.' }
    Mock Get-ChildItem -ModuleName CrossroadsIntegration {
      param($LiteralPath)
      Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -File -Force -ErrorAction Stop
    }
    $summary = Get-CrossroadsDeliverySummary $cache
    $summary.Pending | Should -Be 1
    $summary.Rejected | Should -Be 1
    $summary.Reconciled | Should -Be 1
    $summary.Sent | Should -Be 1
    $summary.TotalFiles | Should -Be 5
    $summary.SizeMB | Should -Be 1
    Should -Invoke Get-ChildItem -ModuleName CrossroadsIntegration -Exactly -Times 1
    Should -Invoke Get-Content -ModuleName CrossroadsIntegration -Exactly -Times 0
    @(Get-ChildItem $cache -File | Get-FileHash).Hash | Should -Be $before
  }

  It 'uses the oldest pending source timestamp and latest cursor, not file times' {
    $null = New-Item -ItemType Directory $cache
    $hash = 'b' * 64
    foreach ($stamp in '20260102T030405000', '20260101T030405000') {
      $file = New-Item -ItemType File (Join-Path $cache "$stamp.ORDER.S80.R90.X00.$hash.json")
      $file.LastWriteTimeUtc = [datetime]'2030-01-01'
      $null = New-Item -ItemType File (Join-Path $cache "$stamp.cursor")
    }
    $summary = Get-CrossroadsDeliverySummary $cache
    $summary.Pending | Should -Be 2
    $summary.OldestPendingSourceUpdate | Should -Be ([datetime]'2026-01-01T03:04:05')
    $summary.OldestPendingSourceUpdate.Kind | Should -Be 'Unspecified'
    $summary.Cursor | Should -Be ([datetime]'2026-01-02T03:04:05')
  }

  It 'includes unrecognized files in size and total but excludes them from state counts' {
    $null = New-Item -ItemType Directory $cache
    $null = New-Item -ItemType File (Join-Path $cache 'invalid.X00.json')
    $null = New-Item -ItemType File (Join-Path $cache 'invalid.cursor')
    $null = New-Item -ItemType Directory (Join-Path $cache 'nested')
    $null = New-Item -ItemType File (Join-Path $cache 'nested/ignored.json')
    $summary = Get-CrossroadsDeliverySummary $cache
    $summary.TotalFiles | Should -Be 2
    $summary.Pending | Should -Be 0
    $summary.Cursor | Should -BeNullOrEmpty
  }

  It 'defaults to caller cache rather than the installed module' {
    Push-Location $TestDrive
    try {
      $null = New-Item -ItemType Directory 'cache' -Force
      $null = New-Item -ItemType File 'cache/20260101T000000000.cursor'
      (Get-CrossroadsDeliverySummary).Cursor | Should -Be ([datetime]'2026-01-01')
    }
    finally { Pop-Location }
  }

  It 'propagates enumeration failures' {
    $null = New-Item -ItemType Directory $cache
    Mock Get-ChildItem -ModuleName CrossroadsIntegration { throw 'Cannot enumerate cache.' }
    { Get-CrossroadsDeliverySummary $cache } | Should -Throw '*Cannot enumerate cache*'
  }
}
