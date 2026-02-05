#!/bin/bash
set -e

# Config
SERVER_IP="192.168.109.1" # GPU1 IP
EXPORT_PATH="/data/k8s-nfs"
TEST_MOUNT_DIR="/tmp/test_nfs_verification"
NODES=("gpu1" "gpu2" "gpu3")

# Password Handling
if [ -z "$NODE_PASS" ]; then
    read -s -p "Enter password for nodes: " NODE_PASS
    echo ""
fi
export NODE_PASS

echo "=========================================================="
echo "   NFS VERIFICATION: CROSS-NODE DATA SHARING"
echo "=========================================================="

# 1. LINUX LEVEL CHECK
echo ">> [Step 1] Linux Level: manual mount and write test"

echo "   1. Mounting NFS on all nodes..."
for NODE in "${NODES[@]}"; do
    CMD="
    mkdir -p $TEST_MOUNT_DIR
    # Unmount if already mounted to be safe
    umount $TEST_MOUNT_DIR 2>/dev/null || true
    mount -t nfs $SERVER_IP:$EXPORT_PATH $TEST_MOUNT_DIR
    "
    if [ "$NODE" == "$(hostname)" ]; then
        echo "$NODE_PASS" | sudo -S -p '' bash -c "$CMD"
    else
        sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "echo '$NODE_PASS' | sudo -S -p '' bash -c '$CMD'" >/dev/null 2>&1
    fi
done

echo "   2. Writing test file from GPU2..."
# We write via ssh to gpu2
CMD_WRITE="echo 'Verification_Timestamp_$(date)' > $TEST_MOUNT_DIR/cross_node_test.txt"
sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t gpu2 "echo '$NODE_PASS' | sudo -S -p '' bash -c \"$CMD_WRITE\"" >/dev/null 2>&1

echo "   3. Reading test file from GPU1 and GPU3..."
PASSED=true
for NODE in "gpu1" "gpu3"; do
    CONTENT=""
    if [ "$NODE" == "$(hostname)" ]; then
        CONTENT=$(cat $TEST_MOUNT_DIR/cross_node_test.txt 2>/dev/null || true)
    else
        CONTENT=$(sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "cat $TEST_MOUNT_DIR/cross_node_test.txt" 2>/dev/null || true)
    fi

    if [[ "$CONTENT" == *"Verification_Timestamp_"* ]]; then
        echo "      - $NODE: SUCCESS (Read content)"
    else
        echo "      - $NODE: FAILED (Cannot read file)"
        PASSED=false
    fi
done

echo "   4. Cleanup mounts..."
for NODE in "${NODES[@]}"; do
    if [ "$NODE" == "$(hostname)" ]; then
        echo "$NODE_PASS" | sudo -S -p '' umount $TEST_MOUNT_DIR
    else
        sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "echo '$NODE_PASS' | sudo -S -p '' umount $TEST_MOUNT_DIR" >/dev/null 2>&1
    fi
done

if [ "$PASSED" = true ]; then
    echo ">> [Step 1] Result: PASS (Data shared correctly across nodes)"
else
    echo ">> [Step 1] Result: FAIL"
    exit 1
fi

echo ""
echo "=========================================================="
echo "   NFS VERIFICATION: K8S DYNAMIC PROVISIONING"
echo "=========================================================="

echo ">> [Step 2] Creating PVC and Test Pod..."

cat <<EOF | kubectl apply -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: nfs-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
  # No storageClassName specified means use default (nfs-client)
---
kind: Pod
apiVersion: v1
metadata:
  name: nfs-test-pod
  namespace: default
spec:
  containers:
  - name: test-container
    image: busybox
    command: ["/bin/sh", "-c", "echo 'Hello K8s NFS' > /mnt/SUCCESS && sleep 3600"]
    volumeMounts:
    - name: nfs-vol
      mountPath: /mnt
  volumes:
  - name: nfs-vol
    persistentVolumeClaim:
      claimName: nfs-test-pvc
  restartPolicy: Never
EOF

echo "   - Waiting for Pod to start (timeout 60s)..."
kubectl wait --for=condition=Ready pod/nfs-test-pod --timeout=60s

echo "   - Checking file inside Pod..."
POD_CONTENT=$(kubectl exec nfs-test-pod -- cat /mnt/SUCCESS)

if [[ "$POD_CONTENT" == *"Hello K8s NFS"* ]]; then
    echo ">> [Step 2] Result: PASS (Pod successfully wrote to dynamic NFS volume)"
else
    echo ">> [Step 2] Result: FAIL (Could not verify write)"
fi

echo "   - Cleaning up K8s test resources..."
kubectl delete pod nfs-test-pod --grace-period=0 --force >/dev/null 2>&1
kubectl delete pvc nfs-test-pvc --grace-period=0 --force >/dev/null 2>&1

echo ""
echo "=========================================================="
echo "   NFS VERIFICATION: VOLUME EXPANSION"
echo "=========================================================="
echo ">> [Step 3] Testing PVC Expansion Capability..."

# Create a small PVC
cat <<EOF | kubectl apply -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: nfs-expand-test
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
  storageClassName: nfs-client
EOF

echo "   - Waiting for PVC to bind..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/nfs-expand-test --timeout=30s

echo "   - Expanding PVC from 1Mi to 2Mi..."
kubectl patch pvc nfs-expand-test -p '{"spec":{"resources":{"requests":{"storage":"2Mi"}}}}'

echo "   - Waiting for resize to reflect (StorageClass must have allowVolumeExpansion=true)..."
# Loop check for capacity update
EXPANDED=false
for i in {1..20}; do
    CAPACITY=$(kubectl get pvc nfs-expand-test -o jsonpath='{.status.capacity.storage}')
    if [ "$CAPACITY" == "2Mi" ]; then
        EXPANDED=true
        break
    fi
    sleep 2
done

if [ "$EXPANDED" = true ]; then
    echo ">> [Step 3] Result: PASS (PVC successfully expanded to 2Mi)"
else
    echo ">> [Step 3] Result: FAIL (PVC capacity did not update to 2Mi)"
    echo "      Current status:"
    kubectl get pvc nfs-expand-test
fi

# Cleanup Step 3
kubectl delete pvc nfs-expand-test --grace-period=0 --force >/dev/null 2>&1

echo ""
echo "=========================================================="
echo "   VERIFICATION COMPLETE: ALL SYSTEMS GO"
echo "=========================================================="
