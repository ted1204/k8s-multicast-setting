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

6) **Setup Storage (Longhorn)**
```bash
# Deploys Longhorn storage
./05-storage-longhorn.sh
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

After joining: configure Harbor/containerd trust and any GPU host prerequisites using the `worker-node/` helpers (for GPU nodes see `worker-node/02-worker-gpu-harbor.sh`).

Repair and test helpers are available in `scripts/tools/` and the repo root `scripts/`:

```bash
# repair helpers
ls -1 scripts/tools

# optional reboot helper
sudo ./09-reboot.sh

# MPS pressure test helpers
./mps-pressure-apply.sh
./mps-pressure-logs.sh
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
- `00-sysctl-tuning.sh` should be run on all nodes (master + workers).
- Use `worker-node/02-worker-gpu-harbor.sh` to configure Harbor trust and the NVIDIA container toolkit on GPU workers.
- Keep the cluster secure: review Harbor/Grafana anonymous access settings before enabling.

## Important cluster notes

- Network and interface settings are environment specific. The interface names, CIDR ranges, and secondary L2 network configurations (macvlan/multus) in `scripts/` are examples and must be updated for your environment. Check and update interface names (for example `eth1` or `enp0s8`), CIDRs, and any hard-coded IPs (such as `MASTER_IP` or `HARBOR_IP`) before running scripts.

- Host network interfaces: Many network installation steps use a host interface directly. Ensure the interface exists and is not managed by other services (for example cloud-init or NetworkManager) before applying changes.

- Storage and `hostPath`: Development manifests or scripts that use `hostPath` or local PVs require attention to directory permissions and SELinux contexts (if applicable). Avoid using `hostPath` in production; use PVCs, Secrets, or ConfigMaps instead.

## Backend and deployment notes

- Initial database and admin account: The project requires an initial database schema and seed. See `backend/infra/db/schema.sql` for the seed data. Provide a `.env` file or Kubernetes Secret with correct database credentials before starting the backend so initialization and seeding can run successfully.

- Backend images and development `hostPath`: During development the backend build and manifests may mount host paths (for example to access local data or certificates). This is for convenience only. For production or shared clusters:
  - Do not use development `hostPath` mounts. Use `PVC`, `Secret`, or `ConfigMap` instead.
  - Edit `backend/scripts/build_image.sh` to set your registry, namespace, image name, and tag before pushing images to your registry.

- Manifest and apply order: Ensure the backend image is built and pushed to the registry, then update manifest image strings and apply manifests. A suggested order:

  1. `kubectl apply -f ca.yaml` (if TLS/CA manifests are required)
  2. `kubectl apply -f go-api.yaml`
  3. `kubectl apply -f postgres.yaml`

  Adjust the order as needed for PV/PVC creation and database readiness.