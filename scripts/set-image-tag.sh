#!/usr/bin/env bash
# Set newTag of every image in the GitOps overlay (used by build_push.sh and by CI).
# Usage: scripts/set-image-tag.sh <TAG>
set -euo pipefail
TAG="${1:?tag}"
FILE="$(cd "$(dirname "$0")/.." && pwd)/deploy/k8s/overlays/gcp/kustomization.yaml"
sed -i.bak -E "s#^(    newTag: ).*#\1${TAG}#" "$FILE" && rm -f "$FILE.bak"
grep -n "newTag" "$FILE"
