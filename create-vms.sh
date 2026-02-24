#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="$BASE_DIR/images/talos-amd64.raw"

echo "Base directory : $BASE_DIR"
echo "Image path     : $IMAGE"

if [[ ! -f "$IMAGE" ]]; then
  echo "ERROR: Talos image not found at $IMAGE"
  echo "Contents of images/:"
  ls -lh "$BASE_DIR/images/" 2>/dev/null || echo "  (images/ directory missing)"
  exit 1
fi

declare -A CLUSTER_NETS=(
  [dev]="talos-dev"
  [staging]="talos-staging"
  [prod]="talos-prod"
)

for CLUSTER in dev staging prod; do
  NET="${CLUSTER_NETS[$CLUSTER]}"
  echo ""
  echo "=== Creating VMs for cluster: $CLUSTER ==="

  for ROLE in controlplane worker; do
    VM_NAME="talos-${CLUSTER}-${ROLE}"
    DISK_PATH="$BASE_DIR/images/${VM_NAME}.qcow2"

    echo "  Creating disk: $DISK_PATH"
    qemu-img create -f qcow2 -b "$IMAGE" -F raw "$DISK_PATH" 20G

    echo "  Creating VM: $VM_NAME"
    virt-install \
      --name "$VM_NAME" \
      --memory 2048 \
      --vcpus 2 \
      --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
      --network "network=${NET},model=virtio" \
      --os-variant generic \
      --boot hd \
      --graphics none \
      --noautoconsole \
      --import

    echo "  Done: $VM_NAME"
  done
done

echo ""
echo "=== All VMs created ==="
virsh list --all
