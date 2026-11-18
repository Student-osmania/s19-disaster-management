<#
.SYNOPSIS
  One-time: write your GCP project id and GitHub repo URL into the GitOps manifests (then commit + push).
.EXAMPLE
  .\scripts\configure.ps1 -ProjectId s19-disaster-123456 -RepoUrl https://github.com/<you>/s19-disaster-management.git
#>
param(
  [Parameter(Mandatory = $true)][string]$ProjectId,
  [Parameter(Mandatory = $true)][string]$RepoUrl,
  [string]$Region = "us-central1"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false     # UTF-8 without BOM, keeps LF line endings

function Update-File([string]$path, [scriptblock]$transform) {
  $text = [System.IO.File]::ReadAllText($path)
  $new = & $transform $text
  if ($new -ne $text) { [System.IO.File]::WriteAllText($path, $new, $utf8); Write-Host "updated $path" }
  else { Write-Host "unchanged $path" }
}

Get-ChildItem (Join-Path $root "deploy/argocd/apps") -Filter *.yaml | ForEach-Object {
  Update-File $_.FullName { param($t) $t.Replace('REPLACE_GIT_REPO_URL', $RepoUrl) }
}
Update-File (Join-Path $root "deploy/k8s/overlays/gcp/kustomization.yaml") {
  param($t) $t.Replace('REPLACE_PROJECT_ID', $ProjectId).Replace('us-central1-docker.pkg.dev', "$Region-docker.pkg.dev")
}
Write-Host "`nConfigured. Next: git add -A; git commit -m 'configure project'; git push" -ForegroundColor Green
