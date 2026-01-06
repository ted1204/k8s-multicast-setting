#!/bin/bash
set -e
NODES=("gpu1" "gpu2" "gpu3")

if [ -z "$NODE_PASS" ]; then
    read -s -p "Enter password for nodes: " NODE_PASS
    echo ""
fi

echo "=========================================================="
echo "   FLUSHING STALE CALICO ROUTES & CONNECTIONS"
echo "=========================================================="

# 1. DELETE STALE/WRONG ROUTES (The 110.x one)
# We find routes going via 192.168.110.x and delete them.
# Calico should re-populate them almost immediately if BGP is working.

# Define the script content to run on remote nodes
REMOTE_SCRIPT=$(cat <<EOF
set -e
# Find routes involving 110.x and delete them if they look like Calico IPIP routes
# Specifically looking for pod CIDRs (10.244.x.x) via 110.x
ip route show | grep 'via 192.168.110' | grep '10.244' | while read -r route; do
    subnet=\$(echo "\$route" | awk '{print \$1}')
    if [ ! -z "\$subnet" ]; then
        echo "   - Deleting stale route: \$subnet via 192.168.110.x"
        echo '$NODE_PASS' | sudo -S -p '' ip route del \$subnet
    fi
done
EOF
)

# Base64 encode the script to avoid quoting issues during SSH
ENCODED_SCRIPT=$(echo "$REMOTE_SCRIPT" | base64 -w0)

for NODE in "${NODES[@]}"; do
    echo ">> Checking Node: $NODE"
    
    if [ "$NODE" == "$(hostname)" ]; then
        # Run locally
        echo "$REMOTE_SCRIPT" | bash
    else
        # Run remotely
        sshpass -p "$NODE_PASS" ssh -o StrictHostKeyChecking=no -t $NODE "echo '$ENCODED_SCRIPT' | base64 -d | bash"
    fi
done

echo ">> Routes flushed. Waiting 10s for BGP convergence..."
sleep 10

echo ">> Verifying Routes on gpu1..."
ip route | grep 10.244 || echo "No 10.244 routes found yet."

echo "=========================================================="
echo "   FLUSH COMPLETE"
echo "=========================================================="
