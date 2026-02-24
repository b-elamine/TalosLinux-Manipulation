# Talos Linux Multi-Cluster Tutorial/LAB

Talos Linux is an immutable, API-driven OS built specifically for Kubernetes. There is no SSH, no shell, no package manager, every interaction with the node goes through `talosctl`. This lab spins up 3 fully isolated Kubernetes clusters (dev, staging, prod) on your local Ubuntu machine using KVM virtual machines, then walks you through managing them end to end.

---

```bash
# Verify virtualization is enabled (must return > 0)
egrep -c '(vmx|svm)' /proc/cpuinfo
```

---

## Tools You Need

| Tool | Purpose |
|------|---------|
| KVM/QEMU | Ubuntu's built-in hypervisor that runs the VMs |
| talosctl | CLI to manage Talos nodes (replaces SSH entirely) |
| kubectl | Standard Kubernetes CLI to manage cluster resources |
| kubectx | Quickly switch between clusters |
| kubens | Quickly switch between namespaces |
| jq | JSON processor used in scripts |

### Install KVM / QEMU

KVM is the kernel module that enables hardware virtualization. QEMU is the emulator that runs on top of it. libvirt is the management layer that wraps both and provides the `virsh` CLI.

```bash
sudo apt update && sudo apt install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  bridge-utils virtinst cpu-checker curl wget jq

sudo usermod -aG libvirt,kvm $USER
newgrp libvirt
sudo systemctl enable --now libvirtd
```

### Install talosctl

```bash
curl -sL https://talos.dev/install | sh
talosctl version --client
```

### Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### Install kubectx & kubens

```bash
sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

---

## Project Structure

```
talos-hands-on/
├── images/
│   ├── talos-amd64.raw                   # shared base image (read-only)
│   ├── talos-dev-controlplane.qcow2
│   ├── talos-dev-worker.qcow2
│   ├── talos-staging-controlplane.qcow2
│   ├── talos-staging-worker.qcow2
│   ├── talos-prod-controlplane.qcow2
│   └── talos-prod-worker.qcow2
├── configs/
│   ├── net-dev.xml
│   ├── net-staging.xml
│   └── net-prod.xml
├── clusters/
│   ├── dev/        (talosconfig, controlplane.yaml, worker.yaml)
│   ├── staging/
│   └── prod/
├── patches/
├── create-vms.sh
├── bootstrap-cluster.sh
└── cluster-status.sh
```

---

## Step 1 — Download the Talos Disk Image

The `metal-amd64.raw` image is the base OS image for all VMs. All 6 VMs share it as a read-only backing file — each VM writes only its own changes to a `.qcow2` overlay on top. This saves significant disk space.

```bash
TALOS_VERSION=$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r '.tag_name')
echo "Downloading Talos $TALOS_VERSION..."

wget -O images/talos-amd64.raw.xz \
  "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.raw.xz"

# Decompress (takes ~1 minute)
xz -d images/talos-amd64.raw.xz

ls -lh images/talos-amd64.raw
```

---

## Step 2 — Create Virtual Networks

Each cluster gets its own isolated NAT network. NAT means the VMs can reach the internet but are completely isolated from each other. The host machine acts as the gateway for each network.

| Cluster | Network Bridge | Subnet |
|---------|---------------|--------|
| dev | virbr-dev | 192.168.101.0/24 |
| staging | virbr-staging | 192.168.102.0/24 |
| prod | virbr-prod | 192.168.103.0/24 |

```bash
for CLUSTER in dev staging prod; do
  case $CLUSTER in
    dev)     SUBNET="192.168.101" ;;
    staging) SUBNET="192.168.102" ;;
    prod)    SUBNET="192.168.103" ;;
  esac

  cat > configs/net-${CLUSTER}.xml <<EOF
<network>
  <name>talos-${CLUSTER}</name>
  <forward mode='nat'/>
  <bridge name='virbr-${CLUSTER}' stp='on' delay='0'/>
  <ip address='${SUBNET}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${SUBNET}.10' end='${SUBNET}.50'/>
    </dhcp>
  </ip>
</network>
EOF

  sudo virsh net-define configs/net-${CLUSTER}.xml
  sudo virsh net-start talos-${CLUSTER}
  sudo virsh net-autostart talos-${CLUSTER}
  echo "Network talos-${CLUSTER} created"
done

# Verify all 3 networks are active
sudo virsh net-list --all
```

---

## Step 3 — Create the VMs

The `create-vms.sh` script creates 6 VMs total (2 per cluster: 1 control plane + 1 worker). Each VM gets a 20GB qcow2 disk that uses the base raw image as its backing file.

```bash
./create-vms.sh
```

What the script does internally for each VM:
- Creates a qcow2 overlay disk on top of the shared base image
- Launches a VM with 2 vCPUs, 2GB RAM, and attaches it to the correct network

---

## Step 4 — Identify VM IPs

After the VMs boot (~30 seconds), they get IPs via DHCP. You need to know which IP belongs to which VM so you can bootstrap correctly. The control plane IP always goes first in the bootstrap command.

```bash
# Wait for VMs to boot
sleep 30

# See all DHCP leases per cluster
for CLUSTER in dev staging prod; do
  echo "=== $CLUSTER ==="
  sudo virsh net-dhcp-leases talos-${CLUSTER}
done
```

Since you get two IPs per cluster with no labels, match them to VM names via MAC address:

```bash
for CLUSTER in dev staging prod; do
  echo "=== $CLUSTER ==="
  for ROLE in controlplane worker; do
    VM="talos-${CLUSTER}-${ROLE}"
    MAC=$(sudo virsh domiflist $VM | awk '/network/ {print $5}')
    echo "  $VM -> MAC: $MAC"
  done
done
```

Compare the MAC addresses printed here with the MAC addresses in the DHCP lease output — that tells you which IP is the control plane and which is the worker.

---

## Step 5 — Bootstrap the Clusters

Bootstrapping does three things: generates machine configs (certificates, tokens, API endpoint), applies them to each node over the network, then tells the control plane to initialize etcd (the key-value store that backs all of Kubernetes).

> **Important:** Only run bootstrap once per cluster. Running it again on an already-bootstrapped cluster will break it.

```bash
# Replace IPs with your actual values from Step 4
./bootstrap-cluster.sh dev     <cp-ip> <worker-ip>
./bootstrap-cluster.sh staging <cp-ip> <worker-ip>
./bootstrap-cluster.sh prod    <cp-ip> <worker-ip>
```

What happens internally during bootstrap:
1. `talosctl gen config` — generates PKI certificates, bootstrap tokens, and machine config files
2. `talosctl apply-config --insecure` — pushes the config to each node over the network (insecure only on first boot before certs exist)
3. Node reboots and applies its config (becomes either a control plane or worker)
4. `talosctl bootstrap` — tells etcd to initialize its first member on the control plane
5. `talosctl kubeconfig` — downloads the kubeconfig so kubectl can talk to the cluster

Each cluster takes 3-5 minutes. Wait for one to fully complete before starting the next.

---

## Step 6 — Merge Kubeconfigs

By default each cluster produces a separate kubeconfig file. Merging them into one file lets you switch between all 3 clusters with a single command.

```bash
mkdir -p ~/.kube

KUBECONFIG=~/.kube/config-dev:~/.kube/config-staging:~/.kube/config-prod \
  kubectl config view --flatten > ~/.kube/config-all

export KUBECONFIG=~/.kube/config-all

# Make it permanent across terminal sessions
echo 'export KUBECONFIG=~/.kube/config-all' >> ~/.bashrc
source ~/.bashrc
```

---

## Step 7 — Verify All Clusters

```bash
# List all available cluster contexts
kubectl config get-contexts

# Check nodes in each cluster
for CTX in dev staging prod; do
  echo "=== $CTX ==="
  kubectl --context=$CTX get nodes -o wide
done
```

Expected output per cluster:
```
NAME                         STATUS   ROLES           AGE   VERSION
talos-dev-controlplane       Ready    control-plane   5m    v1.31.x
talos-dev-worker             Ready    <none>          4m    v1.31.x
```

---

## Step 8 — Switch Between Clusters

`kubectx` sets the active cluster so you don't have to type `--context=` on every command.

```bash
kubectx dev       # all kubectl commands now target dev
kubectx staging   # switch to staging
kubectx prod      # switch to prod
kubectx -         # switch back to the previous cluster
```

---

## Step 9 — Explore Talos Node Management

This is where Talos differs from regular Linux. There is no SSH — you use `talosctl` for everything that would normally require logging into a server.

```bash
# Point talosctl at the cluster you want to inspect
export TALOSCONFIG=~/Desktop/Work/hands-on-projects/talos-hands-on/clusters/dev/talosconfig

# List all system services running on the node (etcd, kubelet, containerd, etc.)
talosctl services --nodes <cp-ip>

# Stream live logs from a service
talosctl logs kubelet --nodes <cp-ip> --follow
talosctl logs etcd    --nodes <cp-ip>

# Kernel messages (equivalent to dmesg on a normal Linux box)
talosctl dmesg --nodes <cp-ip>

# Read the full machine config currently applied to the node
talosctl get machineconfig --nodes <cp-ip> -o yaml

# See all Talos-managed resources (similar to kubectl get all but for the OS layer)
talosctl get all --nodes <cp-ip>

# Network info
talosctl get addresses --nodes <cp-ip>
talosctl get routes    --nodes <cp-ip>

# etcd cluster health
talosctl etcd members --nodes <cp-ip>
talosctl etcd status  --nodes <cp-ip>
```

---

## Step 10 — Deploy Workloads

Deploy a simple nginx app to the dev cluster to verify the Kubernetes layer is fully working.

```bash
kubectl --context=dev create namespace demo

kubectl --context=dev apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-demo
  template:
    metadata:
      labels:
        app: nginx-demo
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo
  namespace: demo
spec:
  selector:
    app: nginx-demo
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

# Watch pods come up (Ctrl+C to stop watching)
kubectl --context=dev get pods -n demo -w
```

---

## Step 11 — Deploy Across All Clusters

This deploys a ConfigMap to all 3 clusters at once, simulating a real multi-environment workflow where the same app is deployed to dev, staging, and prod.

```bash
for CTX in dev staging prod; do
  # Create namespace if it doesn't exist
  kubectl --context=$CTX create namespace demo --dry-run=client -o yaml \
    | kubectl --context=$CTX apply -f -

  kubectl --context=$CTX apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: demo
data:
  cluster: "$CTX"
  deployed_at: "$(date)"
EOF
done

# Verify the ConfigMap exists in all 3 clusters
for CTX in dev staging prod; do
  echo "=== $CTX ==="
  kubectl --context=$CTX get configmap cluster-info -n demo -o jsonpath='{.data}' && echo
done
```

---

## Step 12 — Patch Node Configuration

One of Talos's most powerful features: you can change any node-level configuration (kubelet args, sysctls, kernel modules, etc.) by applying a patch file. The node automatically reboots and picks up the changes without you ever logging in.

### Patch kubelet args on the control plane

```bash
cat > patches/kubelet-patch.yaml <<EOF
machine:
  kubelet:
    extraArgs:
      max-pods: "150"
      node-status-update-frequency: "10s"
EOF

talosctl patch mc \
  --talosconfig clusters/dev/talosconfig \
  --nodes <cp-ip> \
  --patch @patches/kubelet-patch.yaml

# Watch the node come back after it applies the patch
kubectl --context=dev get nodes -w
```

### Patch kernel sysctls on the worker

```bash
cat > patches/sysctl-patch.yaml <<EOF
machine:
  sysctls:
    net.core.somaxconn: "65535"
    vm.max_map_count: "262144"
EOF

talosctl patch mc \
  --talosconfig clusters/dev/talosconfig \
  --nodes <worker-ip> \
  --patch @patches/sysctl-patch.yaml
```

---

## Step 13 — Cluster Health Dashboard

```bash
./cluster-status.sh
```

Or run it manually:

```bash
for CTX in dev staging prod; do
  echo ""
  echo "--- Cluster: $CTX ---"
  kubectl --context=$CTX get nodes
  kubectl --context=$CTX get pods -A --field-selector=status.phase=Running | wc -l | xargs echo "Running pods:"
done
```

---

## Step 14 — Teardown

Removes all VMs and virtual networks cleanly.

```bash
for CLUSTER in dev staging prod; do
  for ROLE in controlplane worker; do
    VM="talos-${CLUSTER}-${ROLE}"
    sudo virsh destroy $VM 2>/dev/null || true
    sudo virsh undefine $VM --remove-all-storage
  done
  sudo virsh net-destroy talos-${CLUSTER}
  sudo virsh net-undefine talos-${CLUSTER}
done
echo "All cleaned up."
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Switch cluster | `kubectx dev` |
| All nodes | `kubectl get nodes -o wide` |
| All pods | `kubectl get pods -A` |
| Node logs | `talosctl logs kubelet --nodes <IP>` |
| Apply config change | `talosctl patch mc --nodes <IP> --patch @file.yaml` |
| Restart a service | `talosctl service restart kubelet --nodes <IP>` |
| etcd members | `talosctl etcd members --nodes <IP>` |
| Read active config | `talosctl get machineconfig --nodes <IP>` |
| List VMs | `virsh list --all` |
| Get VM IPs | `sudo virsh net-dhcp-leases talos-dev` |

---

