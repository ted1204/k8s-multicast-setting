#!/bin/bash
set -e
NODE="gpu3"

if [ -z "$NODE_PASS" ]; then
    read -s -p "Enter password for $NODE: " NODE_PASS
    echo ""
fi

echo "========================================================"
echo "   REPAIRING NVIDIA RUNTIME ON $NODE"
echo "========================================================"

CMD_SCRIPT=$(cat <<EOF
set -e
echo ">> [Remote] Checking NVIDIA Driver..."
if ! command -v nvidia-smi &> /dev/null; then
    echo "   [ERROR] nvidia-smi not found on $NODE."
    exit 1
fi
# Check if driver is responsive
nvidia-smi -L

echo ">> [Remote] Re-configuring Container Runtime (containerd)..."
# Ensure the toolkit is configured as default runtime
if ! command -v nvidia-ctk &> /dev/null; then
    echo "   [INFO] Installing nvidia-container-toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
fi

sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd
echo ">> [Remote] Containerd restarted."
EOF
)

B64_SCRIPT=$(echo "$CMD_SCRIPT" | base64 -w0)

sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "echo '$B64_SCRIPT' | base64 -d | echo '$NODE_PASS' | sudo -S -p '' bash"

echo "========================================================"
echo "   RESTARTING K8S PODS ON $NODE"
echo "========================================================"

# Find the failing DaemonSet pod on gpu3
POD_NAME=$(kubectl get pods -n kube-system -o wide | grep "nvidia-device-plugin-mps-control-daemon" | grep "$NODE" | awk '{print $1}')

if [ ! -z "$POD_NAME" ]; then
    echo ">> Deleting pod $POD_NAME to force restart..."
    kubectl delete pod -n kube-system "$POD_NAME" --grace-period=0 --force
    
    echo ">> Waiting for new pod..."
    sleep 5
    kubectl get pods -n kube-system -o wide | grep "nvidia-device-plugin-mps-control-daemon" | grep "$NODE"
else
    echo ">> No MPS Daemon pod found on $NODE. (Maybe not scheduled yet?)"
fi

echo "Done."
