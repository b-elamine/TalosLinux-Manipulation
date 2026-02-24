# Talos Linux Multi-Cluster Lab — Setup

- Ubuntu 22.04+ with VT-x/AMD-V enabled in BIOS

```bash
# Verify virtualization is enabled (must return > 0)
egrep -c '(vmx|svm)' /proc/cpuinfo
```

---

## Install Dependencies

### KVM / QEMU
```bash
sudo apt update && sudo apt install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  bridge-utils virtinst cpu-checker curl wget jq

sudo usermod -aG libvirt,kvm $USER
newgrp libvirt
sudo systemctl enable --now libvirtd
```

### talosctl
```bash
curl -sL https://talos.dev/install | sh
talosctl version --client
```

### kubectl
```bash
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### kubectx & kubens
```bash
sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

---

## Download Talos Image

```bash
TALOS_VERSION=$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r '.tag_name')

wget -O images/talos-amd64.raw.xz \
  "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.raw.xz"

xz -d images/talos-amd64.raw.xz
```
