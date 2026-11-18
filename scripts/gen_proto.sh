#!/usr/bin/env bash
# Linux/macOS wrapper. The real generator is scripts/gen_proto.py (also used by the Dockerfile and on Windows).
# Usage: scripts/gen_proto.sh [repo_root]
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 "$(cd "$(dirname "$0")" && pwd)/gen_proto.py" "$ROOT"
