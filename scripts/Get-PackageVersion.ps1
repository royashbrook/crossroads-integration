[CmdletBinding()]
param(
  [string]$Repository = '.',
  [switch]$AllowMissing
)

$versions = foreach ($tag in @(& git -C $Repository tag --merged HEAD)) {
  if ($tag -notmatch '^v(?<major>\d+)\.(?<minor>\d+)$') { continue }
  [pscustomobject]@{
    Version = [version]"$($Matches.major).$($Matches.minor)"
    Patch = [int](& git -C $Repository rev-list --count "$tag..HEAD")
  }
}

$version = $versions |
  Sort-Object Patch, @{ Expression = 'Version'; Descending = $true } |
  Select-Object -First 1

if (-not $version) {
  if ($AllowMissing) { return }
  throw 'No reachable vX.Y tag found.'
}

'{0}.{1}.{2}' -f $version.Version.Major, $version.Version.Minor, $version.Patch
