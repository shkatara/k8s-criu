#!/usr/bin/env bash
# Runs the full spot-reclaim scenario end to end (after ./setup.sh):
#   deploy -> checkpoint -> kill node -> salvage -> convert -> restore -> verify
set -euo pipefail

CLUSTER=checkpoint-lab
CP=$CLUSTER-control-plane
DOOMED=$CLUSTER-worker
SURVIVOR=$CLUSTER-worker2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)

banner() {
  echo
  echo "=================================================="
  echo "  $*"
  echo "=================================================="
}

# Curl a pod IP from inside the cluster (pod IPs are not routable from the host).
hit() { docker exec "$CP" curl -s "http://$1:8080/"; }

banner "1/7 Deploying the stateful counter on the doomed node"
kubectl apply -f "$SCRIPT_DIR/k8s/counter-pod.yaml"
kubectl wait --for=condition=ready pod/counter --timeout=120s
POD_IP=$(kubectl get pod counter -o jsonpath='{.status.podIP}')
echo "counter pod is ready on $DOOMED ($POD_IP) — sending 7 requests"
for _ in 1 2 3 4 5 6 7; do hit "$POD_IP"; done

# Record how the container runtime names the app image. The checkpoint refers
# to its base image by this exact reference, and the restore node must know it.
IMAGE_ID=$(kubectl get pod counter -o jsonpath='{.status.containerStatuses[0].imageID}')
echo "container base image reference: $IMAGE_ID"

banner "2/7 The two-minute warning: checkpointing via the kubelet API"
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > "$WORK/kubelet-client.crt"
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > "$WORK/kubelet-client.key"
docker cp "$WORK/kubelet-client.crt" "$DOOMED:/root/"
docker cp "$WORK/kubelet-client.key" "$DOOMED:/root/"

T_WARNING=$(date +%s)
RESPONSE=$(docker exec "$DOOMED" curl -s --insecure \
  --cert /root/kubelet-client.crt --key /root/kubelet-client.key \
  -X POST "https://localhost:10250/checkpoint/default/counter/counter")
echo "kubelet response: $RESPONSE"
TAR_PATH=$(echo "$RESPONSE" | sed -E 's/.*"items":\["([^"]+)".*/\1/')

echo "inspecting the checkpoint archive:"
docker exec "$DOOMED" checkpointctl show "$TAR_PATH"

echo "two more requests AFTER the checkpoint (this work will be lost):"
hit "$POD_IP"; hit "$POD_IP"

banner "3/7 The reclaim: killing the node"
docker stop "$DOOMED"
kubectl delete node "$DOOMED"
kubectl get nodes

banner "4/7 Salvaging the checkpoint off the dead node's disk"
docker cp "$DOOMED:$TAR_PATH" "$WORK/checkpoint.tar"
ls -lh "$WORK/checkpoint.tar"

banner "5/7 Converting the checkpoint into an OCI image"
docker run --rm --privileged -v "$WORK":/work quay.io/buildah/stable:latest bash -c '
  set -e
  ctr=$(buildah from scratch)
  buildah add "$ctr" /work/checkpoint.tar /
  buildah config --annotation=org.criu.checkpoint.container.name=counter "$ctr"
  buildah commit "$ctr" checkpoint-image:latest
  buildah push localhost/checkpoint-image:latest oci-archive:/work/checkpoint-oci.tar:localhost/checkpoint-image:latest
' >/dev/null
ls -lh "$WORK/checkpoint-oci.tar"

banner "6/7 Restoring on the survivor node"
docker cp "$WORK/checkpoint-oci.tar" "$SURVIVOR:/root/"
docker exec "$SURVIVOR" ctr -n k8s.io images import /root/checkpoint-oci.tar

# kind-loaded images are known to containerd only by an "import-<date>@sha256:..."
# reference. The restore path normalizes that to docker.io/library/..., so give
# the survivor an alias under that name. (Clusters that pull from a real
# registry — ECR, GHCR, a local registry — never need this.)
case "$IMAGE_ID" in
  docker.io/library/import-*)
    docker exec "$SURVIVOR" ctr -n k8s.io images tag \
      "${IMAGE_ID#docker.io/library/}" "$IMAGE_ID" >/dev/null || true
    ;;
  import-*)
    docker exec "$SURVIVOR" ctr -n k8s.io images tag \
      "$IMAGE_ID" "docker.io/library/$IMAGE_ID" >/dev/null || true
    ;;
esac

kubectl apply -f "$SCRIPT_DIR/k8s/restore-pod.yaml"
kubectl wait --for=condition=ready pod/counter-restored --timeout=120s
T_RESTORED=$(date +%s)

banner "7/7 The moment of truth"
NEW_IP=$(kubectl get pod counter-restored -o jsonpath='{.status.podIP}')
echo "restored pod is ready on $SURVIVOR ($NEW_IP):"
hit "$NEW_IP"
hit "$NEW_IP"
echo
echo "Recovery took $((T_RESTORED - T_WARNING))s from spot warning to serving again."
echo "(The counter resumed from the checkpoint: post-checkpoint requests were lost,"
echo " exactly like work since your last torch.save.)"
