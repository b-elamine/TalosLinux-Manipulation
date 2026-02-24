#!/bin/bash
for CLUSTER in dev staging prod; do
  echo "=== $CLUSTER ==="
  for ROLE in controlplane worker; do
    VM="talos-${CLUSTER}-${ROLE}"
    MAC=$(sudo virsh domiflist $VM | awk '/network/ {print $5}')
    echo "  $VM -> MAC: $MAC"
  done
done
