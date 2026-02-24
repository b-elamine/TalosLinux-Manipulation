#!/bin/bash
set -e

CLUSTER=$1
CP_IP=$2
WORKER_IP=$3

if [[ -z $CLUSTER || -z $CP_IP || -z $WORKER_IP ]]; then
  echo "Usage: $0 <cluster-name> <controlplane-ip> <worker-ip>"
  exit 1
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$BASE_DIR/clusters/$CLUSTER"
mkdir -p "$CONFIG_DIR"
cd "$CONFIG_DIR"

echo ">>> Generating configs for cluster: $CLUSTER"
talosctl gen config "$CLUSTER" "https://${CP_IP}:6443" \
  --output-dir .

echo ">>> Applying controlplane config to $CP_IP"
talosctl apply-config \
  --insecure \
  --nodes "$CP_IP" \
  --file "$CONFIG_DIR/controlplane.yaml"

echo ">>> Applying worker config to $WORKER_IP"
talosctl apply-config \
  --insecure \
  --nodes "$WORKER_IP" \
  --file "$CONFIG_DIR/worker.yaml"

echo "Waiting 90 seconds for etcd to initialize..."
sleep 90

echo ">>> Bootstrapping etcd on $CP_IP"
talosctl bootstrap \
  --talosconfig "$CONFIG_DIR/talosconfig" \
  --nodes "$CP_IP" \
  --endpoints "$CP_IP"

echo ">>> Waiting 60 seconds for Kubernetes API..."
sleep 60

echo ">>> Fetching kubeconfig for $CLUSTER"
talosctl kubeconfig "$HOME/.kube/config-${CLUSTER}" \
  --talosconfig "$CONFIG_DIR/talosconfig" \
  --nodes "$CP_IP" \
  --endpoints "$CP_IP" \
  --merge=false

echo "=== Cluster $CLUSTER is ready! ==="
echo "Test with: kubectl --kubeconfig ~/.kube/config-${CLUSTER} get nodes"
