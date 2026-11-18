<#
.SYNOPSIS  Set newTag of every image in the GitOps overlay (Windows equivalent of set-image-tag.sh).
.EXAMPLE   .\scripts\set-image-tag.ps1 -Tag v1
#>
param([Parameter(Mandatory = $true)][string]$Tag)
$ErrorActionPreference = 'Stop'
$file = Join-Path (Split-Path -Parent $PSScriptRoot) "deploy/k8s/overlays/gcp/kustomization.yaml"
$text = [System.IO.File]::ReadAllText($file)
$new = [regex]::Replace($text, '(?m)^(    newTag: ).*$', "`${1}$Tag")
[System.IO.File]::WriteAllText($file, $new, (New-Object System.Text.UTF8Encoding $false))
Select-String -Path $file -Pattern 'newTag'
