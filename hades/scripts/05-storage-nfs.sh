#!/bin/bash
set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
NODES=("work1@k8s-work1" "master@k8s-master")
LONGHORN_VERSION="v1.6.0"
DATA_PATH="/data/longhorn"
REPLICA_COUNT=3
NAMESPACE="longhorn-system"

# Interactive Password Prompt
if [ -z "$NODE_PASS" ]; then
    read -s -p "Enter password for nodes (used for SSH & sudo): " NODE_PASS
    echo ""
fi
export NODE_PASS

if ! command -v sshpass &> /dev/null; then
    echo "[INFO] sshpass not found. Installing..."
    echo "$NODE_PASS" | sudo -S apt-get update -qq
    echo "$NODE_PASS" | sudo -S apt-get install -y sshpass -qq
    echo "[OK] sshpass installed successfully."
fi

echo "====================================================="
echo "   PREPARING PRODUCTION LONGHORN STORAGE"
echo "====================================================="

install_dependencies() {
    for NODE in "${NODES[@]}"; do
        echo ">> [Step 1] Configuring Dependencies on $NODE..."
        
        # Longhorn requires open-iscsi and nfs-common (for backups)
        # util-linux is for nsenter
        CMD_CONTENT=$(cat <<EOF
set -e
echo "   - Updating apt cache..."
echo "$NODE_PASS" | sudo -S -p '' apt-get update -qq

echo "   - Installing open-iscsi, nfs-common, cryptsetup..."
echo "$NODE_PASS" | sudo -S -p '' apt-get install -y open-iscsi nfs-common util-linux cryptsetup jq

echo "   - Enabling iscsid service (Required for Longhorn)..."
echo "$NODE_PASS" | sudo -S -p '' systemctl enable --now iscsid

echo "   - Checking Data Path: $DATA_PATH"
if [ ! -d "/data" ]; then
    echo "WARNING: /data directory does not exist on $NODE! Longhorn might fill up your root disk."
else
    echo "$NODE_PASS" | sudo -S -p '' mkdir -p $DATA_PATH
fi
EOF
)
        # Execute via SSH
        B64_CMD=$(echo "$CMD_CONTENT" | base64 -w0)
        if [ "$NODE" == "$(hostname)" ]; then
            echo "$B64_CMD" | base64 -d | bash
        else
            sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "echo '$B64_CMD' | base64 -d | bash"
        fi
    done
}

check_environment() {
    echo ">> [Step 2] Checking Kubernetes connection..."
    if ! kubectl get nodes > /dev/null 2>&1; then
        echo "Error: kubectl is not working. Please check your kubeconfig."
        exit 1
    fi
    echo "   - Kubernetes cluster is reachable."
}

deploy_longhorn() {
    echo ">> [Step 3] Deploying Longhorn via Helm..."

    # Add Helm Repo
    helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
    helm repo update >/dev/null
    
    echo "   - Installing Longhorn Chart (This may take 2-3 minutes)..."
    helm upgrade --install longhorn longhorn/longhorn \
        --namespace $NAMESPACE \
        --create-namespace \
        --version $LONGHORN_VERSION \
        --set defaultSettings.defaultDataPath="$DATA_PATH" \
        --set defaultSettings.defaultReplicaCount=$REPLICA_COUNT \
        --set persistence.defaultClass=true \
        --set persistence.defaultClassReplicaCount=$REPLICA_COUNT \
        --set ingress.enabled=false \
        --wait

    echo ">> Longhorn Deployed Successfully."
}

cleanup_old_nfs() {
    echo ">> [Step 4] Checking for old NFS provisioner..."
    if helm list -n nfs-storage | grep -q "nfs-client"; then
        echo "   - Found old 'nfs-client'. Removing to avoid Default StorageClass conflict..."
        helm uninstall nfs-client -n nfs-storage
        echo "   - Old NFS provisioner removed."
    else
        echo "   - No old NFS provisioner found. Skipping."
    fi
}

install_dependencies
check_environment
cleanup_old_nfs
deploy_longhorn

echo "====================================================="
echo "   LONGHORN SETUP COMPLETE"
echo "====================================================="
echo "1. Access the UI via Port Forwarding:"
echo "   kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80"
echo "   Then open: http://localhost:8080"
echo ""
echo "2. Storage Location: Nodes are configured to store data in '$DATA_PATH'"
echo "3. Default StorageClass: 'longhorn' is now the default."
echo "====================================================="