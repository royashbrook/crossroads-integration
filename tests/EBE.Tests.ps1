BeforeAll {
  Import-Module "$PSScriptRoot/../CrossroadsIntegration/CrossroadsIntegration.psd1" -Force
  $credential = [pscredential]::new('reader', (ConvertTo-SecureString 'synthetic' -AsPlainText -Force))
}
Describe 'EBE source adapter' {
  It 'delegates the caller query and parameters, preserving metadata only' {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ document_id = 7; order_number = '123'; bol_number = 'B1'; indexed_at = '2026-01-01'; source_scope = 'ACCOUNT' }
    }
    $r = Get-CrossroadsEBEData -SqlFile caller.sql -ConnectionString synthetic -Parameters @{ From = '2026-01-01' }
    $r.file_name | Should -Be 'EBE-7.pdf'
    $r.document_id | Should -BeExactly '7'
    $r.source_scope | Should -Be 'ACCOUNT'
    Should -Invoke Get-CrossroadsSqlData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $SqlFile -eq 'caller.sql' -and $ConnectionString -eq 'synthetic' -and $Parameters.From -eq '2026-01-01' -and $Timeout -eq 60
    }
  }
  It 'preserves source query exceptions' {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration { throw 'original SQL exception' }
    { Get-CrossroadsEBEData -SqlFile caller.sql -ConnectionString synthetic } | Should -Throw '*original SQL exception*'
  }
  It 'requires the ShipsDocuments module that owns the portal login and fetch' {
    $manifest = Import-PowerShellDataFile "$PSScriptRoot/../CrossroadsIntegration/CrossroadsIntegration.psd1"
    $required = @($manifest.RequiredModules | Where-Object { $_.ModuleName -eq 'ShipsDocuments' })
    $required.Count | Should -Be 1
    $required[0].ModuleVersion | Should -Be '1.0.0'
  }
  It 'opens the portal session through ShipsDocuments with the caller portal, credential and timeout' {
    Mock New-ShipsSession -ModuleName CrossroadsIntegration { [pscustomobject]@{ BaseUrl = "$BaseUrl/"; Logins = 1 } }
    $s = New-CrossroadsEBESession -BaseUrl https://images.example/portal -Credential $credential -TimeoutSec 33
    $s.BaseUrl | Should -Be 'https://images.example/portal/'
    Should -Invoke New-ShipsSession -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $BaseUrl -eq 'https://images.example/portal' -and $Credential.UserName -eq 'reader' -and $TimeoutSec -eq 33
    }
  }
  It 'surfaces a refused login as the module reports it' {
    Mock New-ShipsSession -ModuleName CrossroadsIntegration { throw 'SHIPS authentication failed.' }
    { New-CrossroadsEBESession -BaseUrl https://images.example -Credential $credential } | Should -Throw '*authentication failed*'
  }
  It 'reads PDF bytes through ShipsDocuments on the given session, as a byte array' {
    Mock Get-ShipsDocument -ModuleName CrossroadsIntegration { ,([Text.Encoding]::ASCII.GetBytes('%PDF-test')) }
    $s = [pscustomobject]@{ BaseUrl = 'https://images.example/portal/' }
    $bytes = Read-CrossroadsEBEDocument -DocumentId 7 -Session $s
    $bytes | Should -BeOfType [byte]
    $bytes.Length | Should -Be 9
    [Text.Encoding]::ASCII.GetString($bytes) | Should -Be '%PDF-test'
    Should -Invoke Get-ShipsDocument -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $DocumentId -eq 7 -and $Session.BaseUrl -eq 'https://images.example/portal/' -and $TimeoutSec -eq 20
    }
  }
  It 'surfaces a non-PDF read as the module reports it' {
    Mock Get-ShipsDocument -ModuleName CrossroadsIntegration { throw 'SHIPS document 7 returned non-PDF content.' }
    { Read-CrossroadsEBEDocument -DocumentId 7 -Session ([pscustomobject]@{}) } | Should -Throw '*non-PDF*'
  }
}
