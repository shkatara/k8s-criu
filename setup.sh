#!/usr/bin/env bash
# Builds the lab for the checkpoint/restore tutorial:
#   - 3-node kind cluster (Kubernetes v1.37.0, containerd 2.3.4)
#   - CRIU 4.2 inside every node (4.1.x breaks on Linux kernels >= 6.16)
#   - containerd's experimental restore-via-create flag enabled
#   - the stateful counter app built and loaded into the cluster
set -euo pipefail

CLUSTER=checkpoint-lab
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

banner() {
  echo
  echo "=================================================="
  echo "  $*"
  echo "=================================================="
}

banner "1/6 Checking prerequisites"
for cmd in docker kind kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not running." >&2; exit 1; }
KIND_MINOR=$(kind version | sed -E 's/^kind v0\.([0-9]+).*/\1/')
if [ "$KIND_MINOR" -lt 33 ]; then
  echo "ERROR: kind >= v0.33.0 is required (found $(kind version))." >&2
  echo "       The demo is pinned to kindest/node:v1.37.0 with containerd 2.3.4." >&2
  exit 1
fi
echo "All prerequisites found."

banner "2/6 Building the counter app image"
docker build -t counter:blog "$SCRIPT_DIR/app"

banner "3/6 Creating the kind cluster (1 control-plane + 2 workers)"
kind delete cluster --name "$CLUSTER" 2>/dev/null || true
kind create cluster --config "$SCRIPT_DIR/k8s/kind-config.yaml"

banner "4/6 Installing CRIU 4.2 inside every node"
# Debian trixie (the kind node OS) ships CRIU 4.1.1, which cannot dump
# TCP sockets on Linux >= 6.16 (SO_PASSCRED getsockopt now returns
# EOPNOTSUPP on non-UNIX sockets; fixed in CRIU 4.2 via criu PR #2711).
# We pull 4.2.x from Debian unstable, pinned low so nothing else upgrades.
for n in $(kind get nodes --name "$CLUSTER"); do
  echo "--- $n"
  docker exec "$n" bash -c '
    echo "deb http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/sid.list
    printf "Package: *\nPin: release a=unstable\nPin-Priority: 100\n" > /etc/apt/preferences.d/sid
    apt-get update -qq >/dev/null
    apt-get install -y -qq criu/unstable checkpointctl >/dev/null
    criu --version
    criu check
  '
done

banner "5/6 Enabling containerd checkpoint restore on every node"
# containerd 2.3.x ships restore-via-CreateContainer disabled by default.
for n in $(kind get nodes --name "$CLUSTER"); do
  echo "--- $n"
  docker exec "$n" bash -c '
    sed -i "s|^\[plugins.\"io.containerd.grpc.v1.cri\"\]$|[plugins.\"io.containerd.grpc.v1.cri\"]\n  enable_experimental_restore_via_create = true|" /etc/containerd/config.toml
    systemctl restart containerd
    containerd config dump | grep enable_experimental_restore_via_create
  '
done
kubectl wait --for=condition=ready node --all --timeout=120s

banner "6/6 Loading the app image into the cluster"
kind load docker-image counter:blog --name "$CLUSTER"

banner "Lab ready"
cat <<'EOF'
Next steps (or run ./demo.sh for the full scripted scenario):

  kubectl apply -f k8s/counter-pod.yaml
  kubectl wait --for=condition=ready pod/counter

Then follow the article: checkpoint, kill the node, restore on the survivor.
EOF
