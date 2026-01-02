#!/bin/bash
set -e
# ==============================================================================
# NVIDIA Setup V10: MPS Individual GPU
# Feature: Uses 'kubectl rollout status' instead of sleep
# ==============================================================================
REPLICAS=${1:-20}
CUSTOM_PREFIX=${2}
TARGET_NODE=${3:-$(kubectl get nodes -o name | head -n 1 | cut -d/ -f2)}
PLUGIN_IMAGE_REPO=${4:-${PLUGIN_IMAGE_REPO:-docker.io/library/k8s-device-plugin}}
PLUGIN_IMAGE_TAG=${5:-${PLUGIN_IMAGE_TAG:-mps-individual}}
MPS_RESOURCE_REPLICAS=$REPLICAS
if [ "$MPS_RESOURCE_REPLICAS" -lt 2 ]; then
  MPS_RESOURCE_REPLICAS=2
fi
if [ -z "$CUSTOM_PREFIX" ] || [ -z "$TARGET_NODE" ] || [ -z "$PLUGIN_IMAGE_REPO" ]; then
  echo "[ERROR] Usage: sudo ./03-install-gpu-drivers.sh <replicas> <resource-prefix> <node-name> <image-repo> [image-tag]"
  echo "Example: sudo ./03-install-gpu-drivers.sh 20 mps gpu1 ghcr.io/you/k8s-device-plugin v0.1.0"
  echo "Hint: You can also set env PLUGIN_IMAGE_REPO and PLUGIN_IMAGE_TAG instead of passing args 4/5."
  exit 1
fi
echo "========================================================"
echo "Strategy: JSON Patch + Kubectl Wait"
echo "Target Node: $TARGET_NODE"
echo "Plugin Image: $PLUGIN_IMAGE_REPO:$PLUGIN_IMAGE_TAG"
echo "Mode: MPS per-GPU, replicas default $REPLICAS"
echo "========================================================"
command_exists() {
  command -v "$1" >/dev/null 2>&1
}
echo "[Step 1] Checking NVIDIA Drivers..."
if command_exists nvidia-smi; then
  CURRENT_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)
  echo "Driver detected: v$CURRENT_DRIVER"
else
  echo "No driver detected. Installing recommended server driver..."
  sudo apt-get update
  sudo apt-get install -y ubuntu-drivers-common
  RECOMMENDED_DRIVER=$(ubuntu-drivers devices | grep "recommended" | awk '{print $3}')
  if [ -z "$RECOMMENDED_DRIVER" ]; then
    echo "Error: Could not detect a recommended driver. Install manually."
    exit 1
  fi
  sudo apt-get install -y "$RECOMMENDED_DRIVER"
  echo "DRIVER INSTALLED. REBOOT REQUIRED. Please reboot and re-run."
  exit 0
fi

echo "[Step 2] Configuring Container Runtime..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd
echo "[Step 3] Cleaning up old resources (mps/gpu)..."
helm uninstall nvidia-device-plugin -n kube-system 2>/dev/null || true
kubectl delete daemonset nvidia-device-plugin nvidia-device-plugin-mps-control-daemon -n kube-system 2>/dev/null || true
kubectl delete configmap nvidia-device-plugin-config nvidia-device-plugin-configs -n kube-system 2>/dev/null || true
sudo rm -f /var/lib/kubelet/device-plugins/nvidia.sock 2>/dev/null || true
kubectl label node "$TARGET_NODE" nvidia.com/mps.capable- 2>/dev/null || true
# kubectl patch node "$TARGET_NODE" --type=json --subresource=status -p='[{"op":"remove","path":"/status/capacity/nvidia.com~1mps-0"},{"op":"remove","path":"/status/capacity/nvidia.com~1mps-1"},{"op":"remove","path":"/status/capacity/nvidia.com~1mps-2"},{"op":"remove","path":"/status/capacity/nvidia.com~1mps-3"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-0"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-1"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-2"},{"op":"remove","path":"/status/allocatable/nvidia.com~1mps-3"}]' 2>/dev/null || true
# kubectl patch node "$TARGET_NODE" --type=json --subresource=status -p='[
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-0"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-1"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-2"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu-3"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu.shared"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-0"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-1"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-2"},
#   {"op":"remove","path":"/status/capacity/nvidia.com~1gpu1-3"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-0"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-1"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-2"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu-3"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu.shared"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-0"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-1"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-2"},
#   {"op":"remove","path":"/status/allocatable/nvidia.com~1gpu1-3"}
# ]' 2>/dev/null || true

echo "Waiting for old pods to terminate..."
kubectl delete pod -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin --force --grace-period=0 2>/dev/null || true
kubectl wait --for=delete pod -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin --timeout=90s 2>/dev/null || true

echo "[Step 3b] Resetting kubelet device-plugin state..."
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl stop kubelet || true
  sudo rm -f /var/lib/kubelet/device-plugins/nvidia*.sock 2>/dev/null || true
  sudo rm -f /var/lib/kubelet/device-plugins/kubelet_internal_checkpoint 2>/dev/null || true
  sudo rm -f /var/lib/kubelet/device-plugins/*.json 2>/dev/null || true
  sudo systemctl start kubelet || true
  kubectl wait --for=condition=Ready node/$TARGET_NODE --timeout=120s 2>/dev/null || true
else
  echo "[WARN] systemctl not found; please manually restart kubelet and clear /var/lib/kubelet/device-plugins if stale resources persist."
fi

echo "[Step 4] Building Helm values (config + image + node)..."
VALUES_FILE=$(mktemp /tmp/nvdp-values-XXXX.yaml)
CONFIG_KEY="individual-gpu-mps"
cat <<EOF > "$VALUES_FILE"
image:
  repository: "$PLUGIN_IMAGE_REPO"
  tag: "$PLUGIN_IMAGE_TAG"

config:
  default: "$CONFIG_KEY"
  fallbackStrategies:
    - named
  map:
    $CONFIG_KEY: |
      version: v1
      flags:
        migStrategy: none
      sharing:
        mps:
          renameByDefault: false
          failRequestsGreaterThanOne: true
          resources:
            - name: nvidia.com/mps
              replicas: $MPS_RESOURCE_REPLICAS
              devices:
EOF

NUM_GPUS=$(nvidia-smi -L | wc -l)
for (( i=0; i<NUM_GPUS; i++ )); do
  printf '                - "%s"\n' "$i" >> "$VALUES_FILE"
done

cat <<EOF >> "$VALUES_FILE"
      individualGPU:
        enabled: true
        namePattern: ${CUSTOM_PREFIX}-%d
        gpuConfigs:
EOF

for (( i=0; i<NUM_GPUS; i++ )); do
  cat <<EOF >> "$VALUES_FILE"
          - index: $i
            name: ${CUSTOM_PREFIX}-${i}
            mps:
              enabled: true
              replicas: $REPLICAS
EOF
done

cat <<EOF >> "$VALUES_FILE"
affinity: null

gfd:
  enabled: false
nfd:
  enabled: false

tolerations:
  - operator: Exists

nodeSelector:
  kubernetes.io/hostname: "$TARGET_NODE"
EOF

echo "[Step 5] Installing Helm Chart..."
kubectl label node "$TARGET_NODE" nvidia.com/mps.capable=true --overwrite
helm upgrade --install nvidia-device-plugin /home/user/k8s/k8s-device-plugin/deployments/helm/nvidia-device-plugin \
  --namespace kube-system \
  --create-namespace \
  -f "$VALUES_FILE" \
  --wait --timeout 180s

echo "[Step 5b] Waiting for DaemonSets to become Ready..."
kubectl rollout status ds/nvidia-device-plugin -n kube-system --timeout=120s || true
kubectl rollout status ds/nvidia-device-plugin-mps-control-daemon -n kube-system --timeout=120s || true

echo "[Step 6] Verifying Node Resources..."
if kubectl describe node "$TARGET_NODE" | grep -q "nvidia.com/${CUSTOM_PREFIX}"; then
  echo "--------------------------------------------------------"
  echo "Configured Resources:"
  kubectl describe node "$TARGET_NODE" | grep "nvidia.com/${CUSTOM_PREFIX}"
  kubectl describe node "$TARGET_NODE" | grep "nvidia.com/mps"
  echo "--------------------------------------------------------"
  echo "Setup Complete."
else
  echo "[WARNING] Pod is running, but resources are not visible yet."
  echo "Please check logs: kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin"
fi