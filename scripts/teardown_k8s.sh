#!/usr/bin/env bash
# Orderly removal of everything Argo CD deployed BEFORE the cluster is destroyed.
# Why: the GKE Ingress (external LB), the Kafka internal LB and the PersistentVolumes are created by
# Kubernetes controllers, not by Terraform. If the cluster is deleted first they can be ORPHANED
# and keep billing (forwarding rules, persistent disks). This script deletes them through Kubernetes,
# waits, then verifies nothing is left.
# Usage: scripts/teardown_k8s.sh <PROJECT_ID>
set -uo pipefail
PROJECT_ID="${1:?project id}"

echo ">> deleting root Argo CD application (cascades to all child apps and their resources)"
kubectl -n argocd patch application s19-root --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null
kubectl -n argocd delete application s19-root --wait=true --timeout=10m 2>/dev/null || true
for app in s19-services monitoring-extras monitoring kafka; do
  kubectl -n argocd delete application "$app" --wait=true --timeout=5m 2>/dev/null || true
done

echo ">> waiting for load balancers and volumes to be released"
for i in $(seq 1 40); do
  ING=$(kubectl -n s19 get ingress --no-headers 2>/dev/null | wc -l)
  LB=$(kubectl get svc -A --no-headers 2>/dev/null | grep -c LoadBalancer)
  PVC=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)
  echo "   ingresses=$ING lb-services=$LB pvcs=$PVC"
  [ "$ING" = 0 ] && [ "$LB" = 0 ] && [ "$PVC" = 0 ] && break
  kubectl delete pvc --all -n s19 --wait=false 2>/dev/null; kubectl delete pvc --all -n kafka --wait=false 2>/dev/null
  sleep 15
done

echo ">> leftover forwarding rules (should be empty):"
gcloud compute forwarding-rules list --project "$PROJECT_ID" --format="table(name,region,IPAddress)"
echo ">> unattached persistent disks (should be empty):"
gcloud compute disks list --project "$PROJECT_ID" --filter="-users:*" --format="table(name,zone,sizeGb)"
echo "Now safe to run: terraform destroy (02-platform) and the 01-foundation pause/destroy."
