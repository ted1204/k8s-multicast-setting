#!/bin/bash

# Reset Kubernetes Cluster Node (Head or Worker)

echo "WARNING: This script will delete the Kubernetes cluster configuration on this node."
echo "It will run 'kubeadm reset', remove configuration files, and flush iptables."
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ">>> Resetting kubeadm..."
sudo kubeadm reset -f

echo ">>> Cleaning up CNI and Kubernetes directories..."
sudo rm -rf /etc/cni/net.d
sudo rm -rf /etc/kubernetes
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/kubelet
sudo rm -rf $HOME/.kube

echo ">>> Flushing iptables..."
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -X

echo ">>> Cleaning up CNI interfaces..."
# Attempt to remove common CNI interfaces if they exist
sudo ip link delete cni0 2>/dev/null
sudo ip link delete flannel.1 2>/dev/null
sudo ip link delete kube-ipvs0 2>/dev/null
sudo ip link delete dummy0 2>/dev/null

echo ">>> Cleaning up IPVS..."
if command -v ipvsadm &> /dev/null; then
    sudo ipvsadm --clear
fi

echo ">>> Cluster reset complete."
echo "You can now re-initialize the cluster using '01-cluster-init.sh' on the head node,"
echo "or join the cluster again on a worker node."
