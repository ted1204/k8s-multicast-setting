# Kubernetes Multicast & GPU Cluster

This repo contains scripts and example manifests to set up a Kubernetes cluster with:

- Calico (pod network)
- Multus + macvlan (secondary L2 network)
- NVIDIA GPU support (optional)
- Longhorn storage
- Monitoring (Prometheus/Grafana + DCGM)
- Harbor (private registry)

This README is a short, script-driven install guide—run the scripts in order. Edit script variables (interface, CIDRs, IPs) before running.
---

## Quick script-driven install (concise)

Run the included scripts in order. Below are the actual scripts in `scripts/` and the recommended order.

Notes: run `00-*` and `06-configure-harbor-registry.sh` on all nodes (master + workers); `01-*`, `02-*`, `04-*`, `05-*`, and dashboard setup on master only; `03-*` on GPU nodes.

Order and commands:

1) System tuning — run on all nodes

```bash
cd k8s-multicast-setting/scripts
sudo ./00-sysctl-tuning.sh
```

2) Initialize Kubernetes (master only)

```bash
sudo ./01-cluster-init.sh
```

Save the `kubeadm join ...` printed by the script and run it on each worker node to join the cluster (or use `get-join-command.sh`).

Worker node steps (example):

On every worker node (or via remote execution):

```bash
cd k8s-multicast-setting/scripts
sudo ./00-sysctl-tuning.sh        # run tuning on worker
# then run the kubeadm join command copied from master, for example:
# sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Alternative: on the master, print the join command and run it on worker:

```bash
ssh user@master 'cd k8s-multicast-setting/scripts && sudo ./get-join-command.sh'
# copy output and run the printed kubeadm join command on the worker node
```

After joining, run the harbor/containerd configuration on each worker:

```bash
sudo ./06-configure-harbor-registry.sh
```

3) Install Multus + macvlan (master only)

```bash
sudo ./02-install-cni-multicast.sh
```

4) GPU support (GPU nodes only)

```bash
sudo ./03-install-gpu-drivers.sh
```

5) Install monitoring, storage, registry (master only)

```bash
sudo ./04-install-monitoring-harbor.sh
```

6) (Optional) Setup public Grafana dashboards (master only)

```bash
sudo ./05-setup-public-dashboards.sh
```

7) Configure Harbor / containerd trust (run on all nodes)

```bash
sudo ./06-configure-harbor-registry.sh
```

8) Priority classes (master only)

```bash
sudo ./07-setup-priority-classes.sh
```

Other helpful scripts:

- `get-join-command.sh` — print or regenerate the `kubeadm join` command for worker nodes
- `reset-cluster.sh` — reset cluster state (use with caution)

Important: there is no `deploy-app` script in this repo. If you need a sample app, check `manifests/` or add your own deployment manifest and apply it with `kubectl apply -f manifests/<your-app>.yaml`.
## Minimal verification

- Check nodes and pods:

```bash
kubectl get nodes
kubectl get pods -A
```

- Check macvlan network attachment definitions:

```bash
kubectl get net-attach-def -A
```

- Check that a pod annotated for macvlan has a secondary interface:

```bash
kubectl describe pod <pod>
kubectl logs <pod>
```

- GPU nodes:

```bash
nvidia-smi   # on host
kubectl get daemonset -n kube-system | grep nvidia
```

- Check Longhorn / monitoring / harbor services:

```bash
kubectl -n longhorn-system get pods
kubectl -n monitoring get pods
kubectl -n harbor get svc
```

## Notes

- Edit script variables (interface name, CIDRs, IP ranges, MASTER_IP) inside `scripts/` before running.
- `00-sysctl-tuning.sh` and `07-configure-harbor-registry.sh` should be run on all nodes (master + workers).
- Keep the cluster secure: review Harbor/Grafana anonymous access settings before enabling.