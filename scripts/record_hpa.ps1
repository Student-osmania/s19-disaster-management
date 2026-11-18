<#
.SYNOPSIS  Record HPA / pod / node state every 15 s into docs/evidence/hpa-scaling.log while k6 runs (Ctrl+C to stop).
           Read-only kubectl (get/top) - deployments are still done exclusively by Argo CD.
#>
$out = Join-Path (Split-Path -Parent $PSScriptRoot) "docs/evidence/hpa-scaling.log"
"# HPA evidence started $((Get-Date).ToUniversalTime().ToString('s'))Z" | Tee-Object -FilePath $out
while ($true) {
  & {
    "=== $((Get-Date).ToUniversalTime().ToString('HH:mm:ss')) ==="
    kubectl -n s19 get hpa
    kubectl -n s19 get deploy incident-intake quorum-coordinator --no-headers
    kubectl -n s19 top pods 2>$null | Select-String -Pattern 'NAME|intake|coordinator'
    kubectl get nodes --no-headers
  } | Tee-Object -FilePath $out -Append
  Start-Sleep -Seconds 15
}
