#Requires -Version 5.1
<#
.SYNOPSIS
  Validate VERSION_MATRIX.json against Makefile / version.py / CHANGELOG.
#>
param(
  [switch]$SkipRepoPins
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$MatrixPath = Join-Path $Root "docs/releases/VERSION_MATRIX.json"
$Makefile = Join-Path $Root "gfc-client/deploy/immortalwrt/package/Makefile"
$NodeVersion = Join-Path $Root "gfc-platform/node-agent/node_agent/version.py"
$ApiSettings = Join-Path $Root "gfc-platform/control-plane/api/app/settings.py"
$Changelog = Join-Path $Root "docs/releases/CHANGELOG.md"

function Get-GfcClient {
  $t = Get-Content -Raw -Encoding UTF8 $Makefile
  if ($t -notmatch '(?m)^PKG_VERSION:=(.+)$') { throw "PKG_VERSION missing" }
  $ver = $Matches[1].Trim()
  if ($t -notmatch '(?m)^PKG_RELEASE:=(.+)$') { throw "PKG_RELEASE missing" }
  $rel = $Matches[1].Trim()
  return "$ver-r$rel"
}

function Get-NodeAgent {
  $t = Get-Content -Raw -Encoding UTF8 $NodeVersion
  if ($t -notmatch 'AGENT_VERSION\s*=\s*["'']([^"'']+)["'']') { throw "AGENT_VERSION missing" }
  return $Matches[1]
}

function Get-ApiVersion {
  $t = Get-Content -Raw -Encoding UTF8 $ApiSettings
  if ($t -notmatch 'api_version:\s*str\s*=\s*["'']([^"'']+)["'']') { throw "api_version missing" }
  return $Matches[1]
}

if (-not (Test-Path $MatrixPath)) { Write-Error "missing $MatrixPath"; exit 1 }
$matrix = Get-Content -Raw -Encoding UTF8 $MatrixPath | ConvertFrom-Json
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

if ($matrix.policy.upgrade -ne "same_major_only") {
  $errors.Add("policy.upgrade must be same_major_only")
}

$current = [string]$matrix.product.current
$row = $matrix.releases | Where-Object { $_.version -eq $current } | Select-Object -First 1
if (-not $row) { $errors.Add("product.current=$current has no releases row") }

if (-not $SkipRepoPins -and $row) {
  $repoClient = Get-GfcClient
  $repoNode = Get-NodeAgent
  $repoApi = Get-ApiVersion
  if ($row.components.gfc_client -and $row.components.gfc_client -ne $repoClient) {
    $errors.Add("gfc_client mismatch: matrix=$($row.components.gfc_client) Makefile=$repoClient")
  }
  if ($row.components.node_agent -and $row.components.node_agent -ne $repoNode) {
    $errors.Add("node_agent mismatch: matrix=$($row.components.node_agent) version.py=$repoNode")
  }
  if ($row.components.control_plane_api -and $row.components.control_plane_api -ne $repoApi) {
    $warnings.Add("control_plane_api differs: matrix=$($row.components.control_plane_api) settings=$repoApi")
  }
  if (Test-Path $Changelog) {
    $cl = Get-Content -Raw -Encoding UTF8 $Changelog
    if ($cl -notmatch "\[$([regex]::Escape($current))\]") {
      $errors.Add("CHANGELOG.md missing section for [$current]")
    }
  } else {
    $errors.Add("missing CHANGELOG.md")
  }
}

foreach ($w in $warnings) { Write-Host "WARN: $w" }
if ($errors.Count -gt 0) {
  foreach ($e in $errors) { Write-Host "ERROR: $e" -ForegroundColor Red }
  Write-Host "check_release: FAIL" -ForegroundColor Red
  exit 1
}

Write-Host "check_release: OK (product.current=$current)"
if (-not $SkipRepoPins) {
  Write-Host "  gfc_client=$(Get-GfcClient)  node_agent=$(Get-NodeAgent)  api=$(Get-ApiVersion)"
}
exit 0
