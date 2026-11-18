#!/usr/bin/env bash
# Records HPA / pod / node state every 15 s into docs/evidence/hpa-scaling.log while k6 runs.
# Read-only kubectl (get/top) - deployments are still done exclusively by Argo CD.
set -uo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/docs/evidence/hpa-scaling.log"
echo "# HPA evidence started $(date -u +%FT%TZ)" | tee "$OUT"
while true; do
  {
    echo "=== $(date -u +%T) ==="
    kubectl -n s19 get hpa
    kubectl -n s19 get deploy incident-intake quorum-coordinator -o wide --no-headers
    kubectl -n s19 top pods 2>/dev/null | grep -E "NAME|intake|coordinator" || true
    kubectl get nodes --no-headers
  } | tee -a "$OUT"
  sleep 15
done
