#!/bin/bash
set -e

echo "=== [Phase 1] Tuning System for Worker Node ==="

# 1. Permanently disable swap to ensure Kubelet stability
sudo swapoff -a
sudo sed -i '/swap/ s/^/#/' /etc/fstab || true

# 2. Load essential kernel modules for networking
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# 3. Configure sysctl parameters (networking & file limits)
cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-tuning.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.file-max = 2097152
vm.swappiness = 0
EOF
sudo sysctl --system

# 4. Install Longhorn storage dependencies (iSCSI & NFS)
sudo apt-get update -qq
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

echo ">>> Phase 1 Complete: System optimized and storage dependencies ready."