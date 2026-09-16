BeforeAll {
  Import-Module "$PSScriptRoot/../CrossroadsIntegration/CrossroadsIntegration.psd1" -Force
}
Describe 'EBE source adapter' {
  It 'delegates the caller query and parameters, preserving metadata only' {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ document_id = 7; order_number = '123'; bol_number = 'B1'; indexed_at = '2026-01-01' }
    }
    $r = Get-CrossroadsEBEData -SqlFile caller.sql -ConnectionString synthetic -Parameters @{ From = '2026-01-01' }
    $r.file_name | Should -Be 'EBE-7.pdf'
    $r.document_id | Should -BeExactly '7'
    Should -Invoke Get-CrossroadsSqlData -ModuleName CrossroadsIntegration -Times 1 -Exactly -ParameterFilter {
      $SqlFile -eq 'caller.sql' -and $ConnectionString -eq 'synthetic' -and $Parameters.From -eq '2026-01-01' -and $Timeout -eq 60
    }
  }
  It 'preserves source query exceptions' {
    Mock Get-CrossroadsSqlData -ModuleName CrossroadsIntegration { throw 'original SQL exception' }
    { Get-CrossroadsEBEData -SqlFile caller.sql -ConnectionString synthetic } | Should -Throw '*original SQL exception*'
  }
  It 'uses a caller-configured portal and ASP.NET form tokens' {
    Mock Invoke-WebRequest -ModuleName CrossroadsIntegration {
      if ($Method -eq 'Post') { return [pscustomobject]@{ Content = 'signed in' } }
      [pscustomobject]@{ Content = '<input name="__VIEWSTATE" value="a&amp;b">' }
    }
    $s = New-CrossroadsEBESession -BaseUrl https://images.example/portal -Username reader -Password synthetic
    $s.BaseUrl | Should -Be 'https://images.example/portal/'
    Should -Invoke Invoke-WebRequest -ModuleName CrossroadsIntegration -Times 1 -ParameterFilter {
      $Method -eq 'Post' -and $Uri -eq 'https://images.example/portal/' -and $Body.__VIEWSTATE -eq 'a&b'
    }
  }
  It 'rejects a returned login form' {
    Mock Invoke-WebRequest -ModuleName CrossroadsIntegration { [pscustomobject]@{ Content = '<input name="UN"><input name="PW">' } }
    { New-CrossroadsEBESession -BaseUrl https://images.example -Username reader -Password synthetic } | Should -Throw '*authentication*'
  }
  It 'reads PDF bytes into memory without a disk image' {
    Mock Invoke-WebRequest -ModuleName CrossroadsIntegration {
      [pscustomobject]@{ RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes('%PDF-test')) }
    }
    $s = [pscustomobject]@{ BaseUrl = 'https://images.example/portal/'; Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
    $bytes = Read-CrossroadsEBEDocument -DocumentId 7 -Session $s
    [Text.Encoding]::ASCII.GetString($bytes) | Should -Be '%PDF-test'
    Should -Invoke Invoke-WebRequest -ModuleName CrossroadsIntegration -Times 1 -ParameterFilter {
      $Uri -eq 'https://images.example/portal/Pages/convertFile.aspx?multiProc=True&doc_id=7'
    }
  }
}
