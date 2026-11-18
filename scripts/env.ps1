<#
.SYNOPSIS
  Dot-source this file in PowerShell to get the S19 helper commands and variables.

.EXAMPLE
  . .\scripts\env.ps1 -Local          # local docker compose stack  -> http://localhost:8080
  . .\scripts\env.ps1                 # GCP: reads the Ingress IP and admin token from Terraform outputs
  s19 GET /api/quorum/config
  s19 POST /api/incidents @{reporterId='demo'; type='FLOOD'; severity='HIGH'; region='north'; description='river overflow'; latitude=28.6; longitude=77.2; peopleAffected=30}

.NOTES
  Requires PowerShell 7.4+ (winget install Microsoft.PowerShell). Works from the repository root.
#>
param(
  [switch]$Local,
  [string]$BaseUrl = ""
)

$RepoRoot = Split-Path -Parent $PSScriptRoot

if ($BaseUrl) {
  $env:S19_BASE = $BaseUrl.TrimEnd('/')
} elseif ($Local) {
  $env:S19_BASE = "http://localhost:8080"
  $env:S19_ADMIN_TOKEN = "local-admin-token"
} else {
  $tf1 = Join-Path $RepoRoot "infra/terraform/01-foundation"
  $tf2 = Join-Path $RepoRoot "infra/terraform/02-platform"
  $ip = (terraform "-chdir=$tf1" output -raw ingress_ip 2>$null)
  if (-not $ip) { Write-Warning "Could not read 'ingress_ip' from Terraform (is 01-foundation applied?)" }
  $env:S19_BASE = "http://$ip"
  $tok = (terraform "-chdir=$tf2" output -raw admin_token 2>$null)
  if ($tok) { $env:S19_ADMIN_TOKEN = $tok } else { Write-Warning "Could not read 'admin_token' from 02-platform" }
}
$env:BASE_URL = $env:S19_BASE                 # used by scripts/*.py and k6
$env:ADMIN_TOKEN = $env:S19_ADMIN_TOKEN

function global:s19 {
  <#
  .SYNOPSIS  Call the S19 API and pretty-print status + JSON.   s19 <METHOD> <PATH> [body-hashtable] [-Admin]
  #>
  param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
    [Parameter(Mandatory = $true, Position = 1)][string]$Path,
    [Parameter(Position = 2)]$Body = $null,
    [switch]$Admin,
    [switch]$Raw
  )
  $headers = @{}
  if ($Admin -and $env:S19_ADMIN_TOKEN) { $headers['X-Admin-Token'] = $env:S19_ADMIN_TOKEN }
  $args2 = @{ Method = $Method; Uri = "$($env:S19_BASE)$Path"; Headers = $headers; SkipHttpErrorCheck = $true;
              StatusCodeVariable = 'code'; TimeoutSec = 30 }
  if ($null -ne $Body) { $args2['Body'] = ($Body | ConvertTo-Json -Depth 10); $args2['ContentType'] = 'application/json' }
  $resp = Invoke-RestMethod @args2
  Write-Host "HTTP $code  $Method $Path" -ForegroundColor $(if ($code -lt 300) { 'Green' } elseif ($code -lt 500) { 'Yellow' } else { 'Red' })
  if ($Raw) { return $resp }
  $resp | ConvertTo-Json -Depth 10
}

Write-Host "S19 API base : $($env:S19_BASE)" -ForegroundColor Cyan
Write-Host ("Admin token  : " + $(if ($env:S19_ADMIN_TOKEN) { 'set' } else { 'NOT set' })) -ForegroundColor Cyan
Write-Host "Try          : s19 GET /api/quorum/config" -ForegroundColor Cyan
