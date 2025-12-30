#!/bin/bash
set -e

# Configuration (Align with 06-configure-harbor-registry.sh)
HARBOR_IP=${1:-"192.168.109.1"}
HARBOR_PORT="30002"

echo "=== [Phase 3] Configuring GPU Support & Harbor Registry ==="

# 1. Install NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# 2. Configure NVIDIA as the default containerd runtime
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd

# 3. Trust Harbor Insecure Registry (HTTP)
sudo sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' /etc/containerd/config.toml
TARGET_DIR="/etc/containerd/certs.d/$HARBOR_IP:$HARBOR_PORT"
sudo mkdir -p "$TARGET_DIR"

cat <<EOF | sudo tee "$TARGET_DIR/hosts.toml" > /dev/null
server = "http://$HARBOR_IP:$HARBOR_PORT"
[host."http://$HARBOR_IP:$HARBOR_PORT"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

sudo systemctl restart containerd
echo ">>> Phase 3 Complete: GPU and Registry configurations applied."