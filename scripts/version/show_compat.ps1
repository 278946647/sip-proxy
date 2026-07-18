#Requires -Version 5.1
param(
  [Parameter(Mandatory = $true)][string]$From,
  [Parameter(Mandatory = $true)][string]$To
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$MatrixPath = Join-Path $Root "docs/releases/VERSION_MATRIX.json"
$matrix = Get-Content -Raw -Encoding UTF8 $MatrixPath | ConvertFrom-Json

function Parse-SemVer([string]$v) {
  $v = $v.TrimStart("v")
  if ($v -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "invalid version: $v" }
  return ,@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}

$fromS = $From.TrimStart("v")
$toS = $To.TrimStart("v")
$a = Parse-SemVer $fromS
$b = Parse-SemVer $toS
$policy = $matrix.policy.upgrade

Write-Host "policy: $policy"
Write-Host "query: $fromS -> $toS"

if (($a[0] -eq $b[0]) -and ($a[1] -eq $b[1]) -and ($a[2] -eq $b[2])) {
  Write-Host "RESULT: ALLOWED (same version)"; exit 0
}
if (($a[0] -gt $b[0]) -or (($a[0] -eq $b[0]) -and ($a[1] -gt $b[1])) -or (($a[0] -eq $b[0]) -and ($a[1] -eq $b[1]) -and ($a[2] -gt $b[2]))) {
  Write-Host "RESULT: DENIED (downgrade not managed)"; exit 1
}

if ($policy -eq "same_major_only" -and $a[0] -ne $b[0]) {
  $toRow = $matrix.releases | Where-Object { $_.version -eq $toS } | Select-Object -First 1
  Write-Host "RESULT: DENIED (cross-major direct upgrade forbidden)"
  if ($toRow -and $toRow.upgrade_path.bridge) {
    Write-Host "  bridge: $($toRow.upgrade_path.bridge)"
  }
  if ($toRow -and $toRow.upgrade_path.migration_doc) {
    Write-Host "  migration_doc: $($toRow.upgrade_path.migration_doc)"
  }
  exit 1
}

$toRow = $matrix.releases | Where-Object { $_.version -eq $toS } | Select-Object -First 1
if (-not $toRow) { Write-Host "RESULT: DENIED (target not in matrix)"; exit 1 }
if ($toRow.status -eq "eol" -or $toRow.status -eq "planned") {
  Write-Host "RESULT: DENIED (target status=$($toRow.status))"; exit 1
}

Write-Host "RESULT: ALLOWED (same major)"
Write-Host "  floors: $($toRow.floors | ConvertTo-Json -Compress)"
exit 0
