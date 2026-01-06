#!/bin/bash
set -e

# ================= CONFIGURATION =================
CALICO_VERSION="v3.29.1"
POD_CIDR=${POD_CIDR:-"10.244.0.0/16"}
# The correct physical network CIDR where nodes communicate
NODE_CIDR="192.168.109.0/24"
# =================================================

echo "=== 2. Install Primary CNI (Calico) ==="

echo "--> Installing Calico binaries manually to /opt/cni/bin..."
sudo mkdir -p /opt/cni/bin
cd /tmp

# Download Calico binaries if not present
if [ ! -f "release-${CALICO_VERSION}.tgz" ]; then
    curl -f -L -O https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/release-${CALICO_VERSION}.tgz
fi
tar -xzf release-${CALICO_VERSION}.tgz
sudo cp -f release-${CALICO_VERSION}/bin/cni/amd64/calico /opt/cni/bin/
sudo cp -f release-${CALICO_VERSION}/bin/cni/amd64/calico-ipam /opt/cni/bin/
sudo chmod +x /opt/cni/bin/calico /opt/cni/bin/calico-ipam
echo "--> Calico binaries installed."

# Install CNI Plugins
if [ ! -f "cni-plugins-linux-amd64-v1.3.0.tgz" ]; then
    curl -L -O https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
fi
sudo tar -xzf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin/

# Download and Prepare Manifest
cd $HOME
curl -O https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

echo "--> Configuring Calico..."
# 1. Set Pod CIDR
sed -i "s|192.168.0.0/16|$POD_CIDR|g" calico.yaml

# 2. Set Node Autodetection (CRITICAL FIX)
# We insert the env var definition into the DaemonSet
# We search for the CALICO_IPV4POOL_IPIP env var and add ours before it
sed -i '/- name: CALICO_IPV4POOL_IPIP/i \            - name: IP_AUTODETECTION_METHOD\n              value: "cidr='"$NODE_CIDR"'"' calico.yaml

echo "--> Applying Calico Manifest..."
kubectl apply -f calico.yaml

echo "--> Waiting for Calico to initialize..."
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout=120s

echo "=== Calico Installed Successfully ==="
echo "Next Step: Join your worker nodes using '03-get-join-command.sh' and running it on each worker."
