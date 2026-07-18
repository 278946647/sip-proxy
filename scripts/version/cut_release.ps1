#Requires -Version 5.1
<#
.SYNOPSIS
  Create immutable annotated tag vX.Y.Z from VERSION_MATRIX.json.
  Never retags. Does not push unless -Push.
#>
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [switch]$DryRun,
  [switch]$Push,
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root
$Version = $Version.TrimStart("v")
$Tag = "v$Version"
$MatrixPath = "docs/releases/VERSION_MATRIX.json"
$Changelog = "docs/releases/CHANGELOG.md"
$NotesDir = "docs/releases/notes"

$matrix = Get-Content -Raw -Encoding UTF8 $MatrixPath | ConvertFrom-Json
$row = $matrix.releases | Where-Object { $_.version -eq $Version } | Select-Object -First 1
if (-not $row) { Write-Error "add releases row for $Version in VERSION_MATRIX.json first"; exit 1 }
if ($row.status -eq "planned") { Write-Error "refuse to tag planned release"; exit 1 }

$cl = Get-Content -Raw -Encoding UTF8 $Changelog
if ($cl -notmatch "\[$([regex]::Escape($Version))\]") {
  Write-Error "CHANGELOG.md missing ## [$Version]"; exit 1
}

$dirty = git status --porcelain
if ($dirty -and -not $AllowDirty) {
  Write-Error "working tree not clean. Commit first or -AllowDirty."
  Write-Host $dirty
  exit 1
}

git rev-parse -q --verify "refs/tags/$Tag" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
  Write-Error "tag $Tag already exists. Never retag. Cut a new PATCH."
  exit 1
}

& "$PSScriptRoot/check_release.ps1"
if ($LASTEXITCODE -ne 0) { Write-Error "check_release failed"; exit 1 }

if (-not (Test-Path "$NotesDir/v$Version.md")) {
  $lines = @(
    "# GFC v$Version",
    "",
    "- **Tag:** ``$Tag``",
    "- **Status:** $($row.status)",
    "",
    "## 摘要",
    "",
    "$(if ($row.notes) { $row.notes } else { '(填写发行说明)' })",
    ""
  )
  New-Item -ItemType Directory -Force -Path $NotesDir | Out-Null
  Set-Content -Encoding UTF8 -Path "$NotesDir/v$Version.md" -Value ($lines -join "`n")
  Write-Host "created notes skeleton: $NotesDir/v$Version.md"
  if (-not $AllowDirty) {
    Write-Error "commit the new notes file, then re-run"
    exit 1
  }
}

if ($DryRun) {
  Write-Host "DRY-RUN: would create annotated tag $Tag"
  exit 0
}

$msg = "GFC $Tag`n`nSee docs/releases/notes/v$Version.md and CHANGELOG.md"
git tag -a $Tag -m $msg
Write-Host "created annotated tag $Tag"
if ($Push) {
  git push origin $Tag
  Write-Host "pushed $Tag"
} else {
  Write-Host "next: git push origin $Tag"
}
Write-Host "IMPORTANT: do not git tag -f / force-push this tag."
exit 0
