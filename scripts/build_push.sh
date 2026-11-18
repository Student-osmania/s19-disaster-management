#!/usr/bin/env bash
# Build all 7 service images and push them to Artifact Registry, then pin the tag in the GitOps overlay.
# (CI does the same on every push to main - use this for the first deployment or without CI.)
# Usage: scripts/build_push.sh <PROJECT_ID> [TAG] [REGION]
set -euo pipefail
PROJECT_ID="${1:?project id}"
TAG="${2:-$(git rev-parse --short HEAD 2>/dev/null || echo v1)}"
REGION="${3:-us-central1}"
REG="${REGION}-docker.pkg.dev/${PROJECT_ID}/s19"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICES=(incident-store quorum-coordinator incident-intake resource-registry dispatch volunteer-coordination situation-analytics)

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
cd "$ROOT"
for s in "${SERVICES[@]}"; do
  echo ">>> building $s:$TAG"
  # --platform: GKE nodes are amd64 (important when building on an Apple-silicon Mac)
  docker build --platform linux/amd64 -f services/Dockerfile --build-arg SERVICE="$s" -t "$REG/$s:$TAG" .
  docker push "$REG/$s:$TAG"
done
"$ROOT/scripts/set-image-tag.sh" "$TAG"
echo "Pushed tag $TAG. Commit + push deploy/k8s/overlays/gcp/kustomization.yaml so Argo CD rolls it out."
