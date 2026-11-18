<#
.SYNOPSIS
  Orderly removal of everything Argo CD deployed BEFORE the cluster is destroyed (Windows version of teardown_k8s.sh).
  The GKE Ingress (external LB), the Kafka internal LB and the PersistentVolumes are created by Kubernetes
  controllers, not by Terraform; deleting the cluster first can ORPHAN them and they keep billing.
.EXAMPLE
  .\scripts\teardown_k8s.ps1 -ProjectId s19-disaster-123456
#>
param([Parameter(Mandatory = $true)][string]$ProjectId)

Write-Host ">> deleting root Argo CD application (cascades to all child apps and their resources)"
$patch = New-TemporaryFile
Set-Content -Path $patch -Value '{"spec":{"syncPolicy":null}}' -NoNewline
kubectl -n argocd patch application s19-root --type merge --patch-file $patch 2>$null
Remove-Item $patch
kubectl -n argocd delete application s19-root --wait --timeout 10m 2>$null
foreach ($app in 's19-services', 'monitoring-extras', 'monitoring', 'kafka') {
  kubectl -n argocd delete application $app --wait --timeout 5m 2>$null
}

Write-Host ">> waiting for load balancers and volumes to be released"
for ($i = 0; $i -lt 40; $i++) {
  $ing = @(kubectl -n s19 get ingress --no-headers 2>$null).Count
  $lb = @(kubectl get svc -A --no-headers 2>$null | Select-String LoadBalancer).Count
  $pvc = @(kubectl get pvc -A --no-headers 2>$null).Count
  Write-Host "   ingresses=$ing lb-services=$lb pvcs=$pvc"
  if ($ing -eq 0 -and $lb -eq 0 -and $pvc -eq 0) { break }
  kubectl delete pvc --all -n s19 '--wait=false' 2>$null | Out-Null
  kubectl delete pvc --all -n kafka '--wait=false' 2>$null | Out-Null
  Start-Sleep -Seconds 15
}
Write-Host ">> leftover forwarding rules (should be empty):"
gcloud compute forwarding-rules list --project $ProjectId --format "table(name,region,IPAddress)"
Write-Host ">> unattached persistent disks (should be empty):"
gcloud compute disks list --project $ProjectId "--filter=-users:*" --format "table(name,zone,sizeGb)"
Write-Host "Now safe to run terraform destroy for 02-platform, then pause/destroy 01-foundation." -ForegroundColor Green
