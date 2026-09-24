Describe 'dependency pins' {
  It 'pins every required module to the exact version its tests ran against' {
    $manifest = Import-PowerShellDataFile "$PSScriptRoot/../CrossroadsIntegration/CrossroadsIntegration.psd1"
    foreach ($required in @($manifest.RequiredModules)) {
      $required | Should -BeOfType [hashtable] -Because 'a bare name loads whatever version is installed'
      $required.RequiredVersion | Should -Not -BeNullOrEmpty -Because "$($required.ModuleName) needs an exact version, not a minimum"
    }
  }
}
