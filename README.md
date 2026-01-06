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

### Phase 1: Cluster Initialization

1) **System Tuning** (Run on **ALL** nodes: Master + Workers)
```bash
cd k8s-cluster-setup/scripts
sudo ./00-sysctl-tuning.sh
```

2) **Initialize Master** (Run on **Master** only)
```bash
sudo ./01-cluster-init.sh
```

3) **Install Primary Network (Calico)** (Run on **Master** only)
```bash
# This sets up Calico with the correct Interface binding (192.168.109.x)
./02-network-calico.sh
```

### Phase 2: Worker Nodes Join

4) **Join Workers**
   - On **Master**, run:
     ```bash
     ./03-get-join-command.sh
     ```
   - Copy the output command.
   - Run it on **EACH Worker Node**.

### Phase 3: Cluster Services (Run on Master)

5) **Install Secondary Network (Multus)**
```bash
./04-network-multus.sh
```

6) **Setup Storage (NFS)**
```bash
# Deploys NFS Provisioner (replaces Longhorn)
./05-storage-nfs.sh
```

7) **Setup GPU Support**
```bash
# Deploys NVIDIA Device Plugin & MPS
./06-gpu-setup.sh
```

8) **Deploy Monitoring & Harbor**
```bash
# Installs Prometheus, Grafana, and Harbor Registry
./07-monitoring.sh
```

### Repair Tools
Located in `scripts/tools/`:
- `repair-gpu-node.sh`: Fixes NVIDIA Runtime issues on a remote node.
- `fix-routes.sh`: Flushes stale routes.


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

## Worker node automation scripts

The `worker-node/` folder contains host-prep helpers when adding nodes to the control plane:

- [worker-node/00-worker-prereqs.sh](worker-node/00-worker-prereqs.sh): swap off, kernel modules, sysctl tuning, iSCSI/NFS deps.
- [worker-node/01-worker-install.sh](worker-node/01-worker-install.sh): installs containerd and Kubernetes v1.35. Export `CONTROL_PLANE_ENDPOINT`, `JOIN_TOKEN`, `DISCOVERY_HASH` (and optionally `NODE_NAME`) to auto-run `kubeadm join` using the containerd socket; otherwise it only installs binaries and holds them.
- [worker-node/02-worker-gpu-harbor.sh](worker-node/02-worker-gpu-harbor.sh): GPU nodes only. Installs a pinned NVIDIA driver, sets up NVIDIA container toolkit, generates CDI spec, and trusts Harbor registry at `HARBOR_IP:HARBOR_PORT` (defaults `192.168.109.1:30002`).
- [worker-node/03-worker-longhorn.sh](worker-node/03-worker-longhorn.sh): Longhorn prerequisites (iSCSI/NFS utils, module loading, kubelet plugin dirs).

Example join flow on a new worker:

```bash
cd k8s-multicast-setting/worker-node
sudo ./00-worker-prereqs.sh
export CONTROL_PLANE_ENDPOINT="10.0.0.10:6443"
export JOIN_TOKEN="abcdef.0123456789abcdef"
export DISCOVERY_HASH="sha256:<hash>"
sudo ./01-worker-install.sh
# GPU nodes only
sudo ./02-worker-gpu-harbor.sh
# Optional: storage prereqs
sudo ./03-worker-longhorn.sh
```
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