#!/bin/bash
set -e

<<<<<<< HEAD
# Nodes Configuration
NODES=("work1@k8s-work1" "master@k8s-master")
NFS_SERVER_NODE="work1@k8s-work1"
NFS_SERVER_IP="10.121.124.22"
EXPORT_PATH="/data/k8s-nfs"
=======
# ==============================================================================
# CONFIGURATION
# ==============================================================================
NODES=("gpu1" "gpu2" "gpu3")
LONGHORN_VERSION="v1.6.0"
DATA_PATH="/data/longhorn"
REPLICA_COUNT=3
NAMESPACE="longhorn-system"
>>>>>>> origin/master

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

<<<<<<< HEAD
# 1. Install NFS Server on gpu1
setup_nfs_server() {
    echo ">> Configuring NFS Server on $NFS_SERVER_NODE..."
    
    CMD_CONTENT=$(cat <<EOF
set -e
echo "$NODE_PASS" | sudo -S -p '' apt-get update -qq
echo "$NODE_PASS" | sudo -S -p '' apt-get install -y nfs-kernel-server

echo "   - Creating export directory: $EXPORT_PATH"
echo "$NODE_PASS" | sudo -S -p '' mkdir -p $EXPORT_PATH
echo "$NODE_PASS" | sudo -S -p '' chown nobody:nogroup $EXPORT_PATH
echo "$NODE_PASS" | sudo -S -p '' chmod 777 $EXPORT_PATH

echo "   - Configuring /etc/exports"
# Backup existing
if [ ! -f /etc/exports.bak ]; then
    echo "$NODE_PASS" | sudo -S -p '' cp /etc/exports /etc/exports.bak
fi

    # CLEANUP: Remove lines starting with digits (previous script error caused password specific artifacts)
    echo "$NODE_PASS" | sudo -S -p '' bash -c "sed -i '/^[0-9]/d' /etc/exports"

    # Add export if not exists
    if ! grep -q "$EXPORT_PATH" /etc/exports; then
        echo "$NODE_PASS" | sudo -S -p '' bash -c "echo '$EXPORT_PATH *(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports"
    fi

echo "   - Restarting NFS Server"
echo "$NODE_PASS" | sudo -S -p '' exportfs -a
echo "$NODE_PASS" | sudo -S -p '' systemctl restart nfs-kernel-server
echo ">> NFS Server Ready"
EOF
)
    # Encode
    B64_CMD=$(echo "$CMD_CONTENT" | base64 -w0)
    
    if [ "$NFS_SERVER_NODE" == *"$(hostname)"* ]; then
        echo "$B64_CMD" | base64 -d | bash
    else
        sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NFS_SERVER_NODE "echo '$B64_CMD' | base64 -d | bash"
    fi
}

# 2. Install Client Packages on ALL nodes
setup_clients() {
=======
install_dependencies() {
>>>>>>> origin/master
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
<<<<<<< HEAD
        
        if [ "$NODE" == *"$(hostname)"* ]; then
=======
        if [ "$NODE" == "$(hostname)" ]; then
>>>>>>> origin/master
            echo "$B64_CMD" | base64 -d | bash
        else
            sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "echo '$B64_CMD' | base64 -d | bash"
        fi
    done
}

<<<<<<< HEAD
# 3. Deploy Kubernetes NFS Provisioner
setup_k8s_provisioner() {
    if ! command -v helm &> /dev/null; then
        echo "[INFO] Helm not found. Installing via official script..."
        
        # 先安裝依賴工具
        echo "$NODE_PASS" | sudo -S apt-get install -y curl -qq
        
        # 下載官方安裝腳本
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        
        # 賦予執行權限
        chmod 700 get_helm.sh
        
        # 執行安裝 (腳本內部會自動處理 sudo)
        echo "$NODE_PASS" | sudo -S ./get_helm.sh
        
        # 清理
        rm get_helm.sh
        echo "[OK] Helm installed successfully."
    fi
    echo ">> Deploying NFS Subdir External Provisioner..."
    
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
    helm repo update >/dev/null

    helm upgrade --install nfs-client nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --namespace nfs-storage \
        --create-namespace \
        --set nfs.server=$NFS_SERVER_IP \
        --set nfs.path=$EXPORT_PATH \
        --set storageClass.name=nfs-client \
        --set storageClass.defaultClass=true \
        --set storageClass.allowVolumeExpansion=true

    echo ">> NFS Provisioner Installed."
=======
check_environment() {
    echo ">> [Step 2] Checking Kubernetes connection..."
    if ! kubectl get nodes > /dev/null 2>&1; then
        echo "Error: kubectl is not working. Please check your kubeconfig."
        exit 1
    fi
    echo "   - Kubernetes cluster is reachable."
>>>>>>> origin/master
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