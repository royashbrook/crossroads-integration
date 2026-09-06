Describe 'package version' {
  BeforeAll {
    $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' 'Get-PackageVersion.ps1'
    $repo = Join-Path ([IO.Path]::GetTempPath()) "crossroads-version-$([guid]::NewGuid())"
    New-Item -ItemType Directory $repo | Out-Null
    & git -C $repo init --quiet
    & git -C $repo config user.email 'test@example.com'
    & git -C $repo config user.name 'Test'
    Set-Content (Join-Path $repo file.txt) '0'
    & git -C $repo add .
    & git -C $repo commit --quiet -m initial
  }

  AfterAll {
    Remove-Item $repo -Recurse -Force
  }

  It 'uses the nearest vX.Y tag and commit count' {
    @(& $script -Repository $repo -AllowMissing).Count | Should -Be 0
    & git -C $repo tag v1.2
    1..2 | ForEach-Object {
      Set-Content (Join-Path $repo file.txt) $_
      & git -C $repo commit --quiet -am "commit $_"
    }

    & $script -Repository $repo | Should -Be '1.2.2'
    & git -C $repo tag v2.0
    & $script -Repository $repo | Should -Be '2.0.0'
  }
}
