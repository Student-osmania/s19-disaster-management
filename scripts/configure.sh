#!/usr/bin/env bash
# One-time: write your GCP project id and Git repo URL into the GitOps manifests, then commit.
# Usage: scripts/configure.sh <PROJECT_ID> <GIT_REPO_HTTPS_URL> [REGION]
#   e.g. scripts/configure.sh s19-disaster-123456 https://github.com/me/s19-disaster-management.git
set -euo pipefail
PROJECT_ID="${1:?project id}"
REPO_URL="${2:?git repo https url}"
REGION="${3:-us-central1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sed -i.bak "s#REPLACE_GIT_REPO_URL#${REPO_URL}#g" "$ROOT"/deploy/argocd/apps/*.yaml
sed -i.bak -e "s#REPLACE_PROJECT_ID#${PROJECT_ID}#g" -e "s#us-central1-docker.pkg.dev#${REGION}-docker.pkg.dev#g" \
  "$ROOT/deploy/k8s/overlays/gcp/kustomization.yaml"
find "$ROOT/deploy" -name "*.bak" -delete
echo "Configured. Review with: git diff deploy/   then: git commit -am 'configure project' && git push"
