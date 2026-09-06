BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../CrossroadsIntegration/CrossroadsIntegration.psd1') -Force
  $order = [pscustomobject]@{
    order_number = 'TEST100'
    updated_date = '2026-01-02T03:04:05'
    progress = 'assigned'
    hold = ''
    requests = @([pscustomobject]@{
      kind = 'create'; path = '/order/create'; message_key = 'create'
      payload_json = '{"origin_order_number":"TEST100"}'
    })
  }
  $delivery = @{ BaseUrl = 'https://example.invalid'; Tenant = 'SOURCE'; DestinationTenant = 'DESTINATION' }
}

Describe 'Caller cache defaults' {
  BeforeEach {
    Mock Get-CrossroadsToken -ModuleName CrossroadsIntegration { 'test-token' }
    Mock Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ http = 200; data = [pscustomobject]@{ status = 'synced' } }
    }
  }

  It 'uses each caller directory without retaining a previous default' {
    foreach ($name in 'first','second') {
      $path = Join-Path $TestDrive $name
      $null = New-Item -ItemType Directory $path
      Push-Location $path
      try {
        Initialize-CrossroadsDelivery
        Get-CrossroadsDeliveryCursor | Should -BeNullOrEmpty
        $staged = @(Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery)
        $staged.Count | Should -Be 1
        [IO.Path]::IsPathRooted($staged[0].file) | Should -BeTrue
        Split-Path $staged[0].file | Should -Be (Join-Path $path 'cache')
        $null = Set-CrossroadsDeliveryCursor -Current $null -Rows @($order)
        Get-CrossroadsDeliveryCursor | Should -Be ([datetime]$order.updated_date)
        $results = @(Send-CrossroadsDelivery -ClientId test -ClientSecret test @delivery)
        $results.Count | Should -Be 1
        $results[0].state | Should -Be 'sent'
        @(Add-CrossroadsDelivery -Orders @($order) -Persist $true @delivery).Count | Should -Be 0
      }
      finally { Pop-Location }
    }
    Should -Invoke Invoke-CrossroadsRequest -ModuleName CrossroadsIntegration -Times 2 -Exactly
  }

  It 'uses an explicit override without creating a default cache' {
    $path = Join-Path $TestDrive 'caller'
    $override = Join-Path $TestDrive 'override'
    $null = New-Item -ItemType Directory $path
    Push-Location $path
    try {
      Initialize-CrossroadsDelivery -CacheDir $override
      $staged = @(Add-CrossroadsDelivery -Orders @($order) -CacheDir $override -Persist $true @delivery)
      Split-Path $staged[0].file | Should -Be $override
      $null = Set-CrossroadsDeliveryCursor -CacheDir $override -Current $null -Rows @($order)
      Get-CrossroadsDeliveryCursor -CacheDir $override | Should -Be ([datetime]$order.updated_date)
      $results = @(Send-CrossroadsDelivery -CacheDir $override -ClientId test -ClientSecret test @delivery)
      $results[0].state | Should -Be 'sent'
      Test-Path (Join-Path $path 'cache') | Should -BeFalse
    }
    finally { Pop-Location }
  }
}
