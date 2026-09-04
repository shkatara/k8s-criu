#!/usr/bin/env bash
# Deletes the kind cluster and the demo image.
set -euo pipefail

kind delete cluster --name checkpoint-lab
docker rmi counter:blog 2>/dev/null || true
echo "Lab deleted."
