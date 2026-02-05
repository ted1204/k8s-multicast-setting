#!/bin/bash
set -e
LOG_FILE="/tmp/network_check_$(date +%s).log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "========================================================"
echo "      COMPREHENSIVE NETWORK DIAGNOSTIC TOOL"
echo "========================================================"

# Nodes
NODES=("gpu1" "gpu2" "gpu3")
POD_CIDR="10.244.0.0/16" 

# 1. NODE STATUS
echo "[1] Checking Node Status..."
kubectl get nodes -o wide

# 2. SYSTEM PODS STATUS
echo ""
echo "[2] Checking System Pods (CNI / DNS / Proxy)..."
kubectl get pods -n kube-system -o wide | grep -E 'calico|coredns|kube-proxy'

# 3. DEPLOY TEST PODS ON EVERY NODE
echo ""
echo "[3] Deploying Net-Test Pods on all nodes..."

for NODE in "${NODES[@]}"; do
    POD_NAME="net-test-$NODE"
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: default
  labels:
    app: net-test
    node: $NODE
spec:
  nodeName: $NODE
  containers:
  - name: toolbox
    image: praqma/network-multitool
    command: ["sleep", "3600"]
  terminationGracePeriodSeconds: 0
EOF
done

echo "   - Waiting for test pods to be ready..."
kubectl wait --for=condition=Ready pod -l app=net-test --timeout=60s || {
    echo "   [ERROR] Test pods failed to start. Aborting connectivity check."
    kubectl get pods -l app=net-test -o wide
    # exit 1
}

# Collect IPs
declare -A POD_IPS
for NODE in "${NODES[@]}"; do
    POD_NAME="net-test-$NODE"
    IP=$(kubectl get pod $POD_NAME -o jsonpath='{.status.podIP}')
    POD_IPS[$NODE]=$IP
    echo "   - $NODE Pod IP: $IP"
done

# 4. CROSS-NODE PING TEST
echo ""
echo "[4] Running Cross-Node Ping Tests (Pod-to-Pod)..."

FAIL_COUNT=0

for SOURCE_NODE in "${NODES[@]}"; do
    SOURCE_POD="net-test-$SOURCE_NODE"
    
    for DEST_NODE in "${NODES[@]}"; do
        if [ "$SOURCE_NODE" == "$DEST_NODE" ]; then continue; fi
        
        DEST_IP=${POD_IPS[$DEST_NODE]}
        echo -n "   - $SOURCE_NODE -> $DEST_NODE ($DEST_IP): "
        
        if kubectl exec $SOURCE_POD -- ping -c 2 -W 1 $DEST_IP >/dev/null 2>&1; then
            echo "PASS"
        else
            echo "FAIL"
            FAIL_COUNT=$((FAIL_COUNT+1))
        fi
    done
done

# 5. DNS RESOLUTION TEST
echo ""
echo "[5] Running DNS Resolution Tests (CoreDNS)..."
DNS_FAIL_COUNT=0
for NODE in "${NODES[@]}"; do
    POD_NAME="net-test-$NODE"
    echo -n "   - $NODE resolving 'kubernetes.default': "
    
    if kubectl exec $POD_NAME -- nslookup kubernetes.default >/dev/null 2>&1; then
        echo "PASS"
    else
        echo "FAIL"
        DNS_FAIL_COUNT=$((DNS_FAIL_COUNT+1))
    fi
done

# 6. CLEANUP
echo ""
echo "[6] Cleaning up test pods..."
kubectl delete pod -l app=net-test --grace-period=0 --force >/dev/null 2>&1

echo ""
echo "========================================================"
echo "DIAGNOSTIC SUMMARY:"
if [ "$FAIL_COUNT" -eq 0 ] && [ "$DNS_FAIL_COUNT" -eq 0 ]; then
    echo "Result: HEALTHY (All checks passed)"
else
    echo "Result: UNHEALTHY"
    echo "   - Ping Failures: $FAIL_COUNT"
    echo "   - DNS Failures:  $DNS_FAIL_COUNT"
    echo ""
    echo "SUGGESTED ACTION: If Ping failed, it's CNI/Firewall. If Ping worked but DNS failed, check CoreDNS."
fi
echo "========================================================"
