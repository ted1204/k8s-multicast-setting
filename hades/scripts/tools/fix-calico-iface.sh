#!/bin/bash
set -e

echo "=========================================================="
echo "   FIXING CALICO INTERFACE MISMATCH"
echo "=========================================================="

echo ">> Current Status: Calico is binding to the WRONG network (192.168.110.x)."
echo ">> Target Status:  Force Calico to use the Cluster Network (192.168.109.x)."

# Patching the DaemonSet
# We set IP_AUTODETECTION_METHOD to use the CIDR 192.168.109.0/24
# This ensures it picks the interface with the IP that matches the K8s node IP.

echo ">> Patching kube-system/calico-node DaemonSet..."
kubectl set env daemonset/calico-node -n kube-system IP_AUTODETECTION_METHOD=cidr=192.168.109.0/24

echo ">> Waiting for rollout to trigger..."
sleep 5

echo ">> Restarting Calico pods to apply changes..."
kubectl -n kube-system delete pod -l k8s-app=calico-node --grace-period=0 --force

echo ">> Waiting for Calico to initialize (approx 60s)..."
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout=120s

echo ">> Verifying new interface selection..."
# We'll check the logs of one of the new pods
sleep 10
POD=$(kubectl get pod -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}')
echo "   Checking logs of $POD..."
kubectl -n kube-system logs $POD | grep "Using autodetected IPv4" || echo "   (Log not found yet, but config is applied)"

echo "=========================================================="
echo "   CALICO FIX APPLIED"
echo "=========================================================="
echo "Please run ./diagnose_network.sh again to confirm connectivity."
