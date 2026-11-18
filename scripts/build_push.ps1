<#
.SYNOPSIS
  Build the 7 service images with Docker Desktop, push them to Artifact Registry and pin the tag in the
  GitOps overlay. (After the first deployment GitHub Actions does this automatically on every push.)
.EXAMPLE
  .\scripts\build_push.ps1 -ProjectId s19-disaster-123456 -Tag v1
#>
param(
  [Parameter(Mandatory = $true)][string]$ProjectId,
  [string]$Tag = "v1",
  [string]$Region = "us-central1"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$reg = "$Region-docker.pkg.dev/$ProjectId/s19"
$services = @('incident-store', 'quorum-coordinator', 'incident-intake', 'resource-registry', 'dispatch',
              'volunteer-coordination', 'situation-analytics')

gcloud auth configure-docker "$Region-docker.pkg.dev" --quiet
if ($LASTEXITCODE -ne 0) { throw "gcloud auth configure-docker failed" }
Push-Location $root
try {
  foreach ($s in $services) {
    Write-Host ">>> building $s`:$Tag" -ForegroundColor Cyan
    # --platform: GKE nodes are linux/amd64
    docker build --platform linux/amd64 -f services/Dockerfile --build-arg SERVICE=$s -t "$reg/$s`:$Tag" .
    if ($LASTEXITCODE -ne 0) { throw "docker build $s failed" }
    docker push "$reg/$s`:$Tag"
    if ($LASTEXITCODE -ne 0) { throw "docker push $s failed" }
  }
} finally { Pop-Location }
& (Join-Path $PSScriptRoot "set-image-tag.ps1") -Tag $Tag
Write-Host "`nPushed tag $Tag. Commit + push deploy/k8s/overlays/gcp/kustomization.yaml so Argo CD rolls it out." -ForegroundColor Green
