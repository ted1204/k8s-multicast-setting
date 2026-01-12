#!/bin/bash
set -e

# ========================================================
#   GLOBAL CONFIGURATION (PRODUCTION)
# ========================================================
HARBOR_NAMESPACE="harbor"
MONITOR_NAMESPACE="monitoring"
INSTALLER_NAMESPACE="harbor-certs"
LONGHORN_NAMESPACE="longhorn-system"

HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-"HarborProd123!"}
STORAGE_HOSTNAME="gpu1-storage"

# === [NETWORK CONFIGURATION] ===
# 1. UI/Management IP (1Gbps) - For Admin Browser Access
UI_IP="192.168.109.1"

# 2. Data/Storage IP (25Gbps) - For High Speed Docker Pull/Push
DATA_IP="192.168.110.1"

# === [PORTS CONFIGURATION] ===
# Static NodePorts for consistent access
HTTPS_NODE_PORT=30003   # Harbor HTTPS
HTTP_NODE_PORT=30002    # Harbor HTTP (Redirect)
GRAFANA_PORT=30004      # Grafana UI
LONGHORN_UI_PORT=30005  # Longhorn UI (New)

# Paths & Storage
CERTS_DIR="certs"
CERT_CONFIGMAP_PATH="/tmp/harbor-ca-configmap.yaml"
CERT_DAEMONSET_PATH="/tmp/harbor-ca-daemonset.yaml"
STORAGE_CLASS="longhorn"
DCGM_MANIFEST_PATH="../manifests/gpu/gpu-exporter.yaml"

# Logging Helpers
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] INFO:${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARN:${NC} $1"; }
step() { echo -e "${CYAN}--------------------------------------------------------\n[STEP] $1\n--------------------------------------------------------${NC}"; }

# ========================================================
#   START DEPLOYMENT
# ========================================================

step "1. Network & Pre-flight Checks"
log "Management Interface (UI):   $UI_IP"
log "Storage Interface (Data):    $DATA_IP"

# Sanity Check for 25Gb subnet
if [[ "$DATA_IP" != "192.168.110."* ]]; then
    warn "Warning: DATA_IP ($DATA_IP) does not look like the 110.x subnet."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
fi

# Check Helm
if ! command -v helm &> /dev/null; then
    log "Helm not found. Installing..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

step "2. Certificate Generation (Dual-IP Support)"
log "Generating SSL certificates for both $UI_IP and $DATA_IP..."
mkdir -p "$CERTS_DIR"

# Generate CA
openssl genrsa -out "$CERTS_DIR/ca.key" 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=Harbor-CA" \
 -key "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt"

# Generate Server Key
openssl genrsa -out "$CERTS_DIR/harbor.key" 4096
openssl req -new -key "$CERTS_DIR/harbor.key" -out "$CERTS_DIR/harbor.csr" \
  -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=$DATA_IP"

# V3 Extension (Subject Alternative Name)
cat > "$CERTS_DIR/v3.ext" <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
IP.1 = $DATA_IP
IP.2 = $UI_IP
DNS.1 = $STORAGE_HOSTNAME
EOF

# Sign Certificate
openssl x509 -req -in "$CERTS_DIR/harbor.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
 -out "$CERTS_DIR/harbor.crt" -days 3650 -sha512 -extfile "$CERTS_DIR/v3.ext"

log "Certificates generated successfully."

step "3. Prepare Kubernetes Secrets"
step "3. Prepare Kubernetes Secrets"
# Create namespaces
kubectl create namespace $HARBOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $MONITOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $INSTALLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Harbor HTTPS Secret
kubectl -n $HARBOR_NAMESPACE delete secret harbor-https-secret --ignore-not-found
kubectl -n $HARBOR_NAMESPACE create secret tls harbor-https-secret \
  --key "$CERTS_DIR/harbor.key" \
  --cert "$CERTS_DIR/harbor.crt"

# Docker Registry Credential (Global Sync)
REGISTRY_NAMESPACES="default harbor monitoring longhorn-system nfs-storage $(kubectl get ns --field-selector status.phase=Active -o jsonpath='{.items[*].metadata.name}')"
REGISTRY_NAMESPACES=$(echo "$REGISTRY_NAMESPACES" | tr ' ' '\n' | sort -u | tr '\n' ' ')

log "Syncing Docker Registry Secret to all namespaces..."
for NS in $REGISTRY_NAMESPACES; do
  # Skip kube-public or kube-node-lease if needed, but usually okay
  # [FIX] Add '|| true' to prevent script exit on failure
  kubectl delete secret harbor-regcred -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
  
  kubectl create secret docker-registry harbor-regcred \
    --docker-server="$DATA_IP:$HTTPS_NODE_PORT" \
    --docker-username="admin" \
    --docker-password="$HARBOR_ADMIN_PASSWORD" \
    --docker-email="admin@example.com" \
    -n "$NS" >/dev/null 2>&1 || true
done
log "Secret sync complete."

step "4. Distribute CA to Nodes (Containerd Trust)"
log "Configuring all nodes to trust Harbor CA on port $HTTPS_NODE_PORT..."

# ConfigMap
cat > "$CERT_CONFIGMAP_PATH" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-ca-cert
  namespace: $INSTALLER_NAMESPACE
data:
  ca.crt: |
$(sed 's/^/    /' "$CERTS_DIR/ca.crt")
EOF

# DaemonSet
cat > "$CERT_DAEMONSET_PATH" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: harbor-cert-installer
  namespace: $INSTALLER_NAMESPACE
spec:
  selector:
    matchLabels:
      app: harbor-cert-installer
  template:
    metadata:
      labels:
        app: harbor-cert-installer
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
      - operator: Exists
      initContainers:
      - name: install-cert
        image: alpine:latest
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e
            apk add --no-cache util-linux >/dev/null
            
            # Using DATA_IP for internal node communication
            TARGET_IP="$DATA_IP"
            TARGET_PORT="$HTTPS_NODE_PORT"
            
            CONFIG_TOML="/host/etc/containerd/config.toml"
            HOSTS_DIR="/host/etc/containerd/certs.d/\$TARGET_IP:\$TARGET_PORT"
            HOSTS_FILE="\$HOSTS_DIR/hosts.toml"
            
            echo "Installing CA for \$TARGET_IP..."

            # 1. Containerd Config Check
            if [ ! -f "\$CONFIG_TOML" ]; then
              mkdir -p /host/etc/containerd
              nsenter --mount=/proc/1/ns/mnt -- containerd config default > "\$CONFIG_TOML"
            fi
            
            if grep -q 'config_path = ""' "\$CONFIG_TOML"; then
              sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "\$CONFIG_TOML"
            fi

            # 2. Create certs.d entry
            mkdir -p "\$HOSTS_DIR"
            cp /config/ca.crt "\$HOSTS_DIR/ca.crt"
            
            printf 'server = "https://%s:%s"\n' "\$TARGET_IP" "\$TARGET_PORT" > "\$HOSTS_FILE"
            printf '[host."https://%s:%s"]\n' "\$TARGET_IP" "\$TARGET_PORT" >> "\$HOSTS_FILE"
            printf '  capabilities = ["pull", "resolve", "push"]\n' >> "\$HOSTS_FILE"
            printf '  ca = "/etc/containerd/certs.d/%s:%s/ca.crt"\n' "\$TARGET_IP" "\$TARGET_PORT" >> "\$HOSTS_FILE"

            # 3. Reload Containerd
            echo "Reloading containerd..."
            nsenter --mount=/proc/1/ns/mnt -- systemctl restart containerd
        volumeMounts:
        - name: host-etc
          mountPath: /host/etc
        - name: cert-config
          mountPath: /config
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
      volumes:
      - name: host-etc
        hostPath:
          path: /etc
      - name: cert-config
        configMap:
          name: harbor-ca-cert
EOF

kubectl delete daemonset harbor-cert-installer -n $INSTALLER_NAMESPACE --ignore-not-found >/dev/null
kubectl apply -f "$CERT_CONFIGMAP_PATH"
kubectl apply -f "$CERT_DAEMONSET_PATH"
log "Waiting for CA distribution..."
kubectl rollout status daemonset/harbor-cert-installer -n $INSTALLER_NAMESPACE --timeout=180s

step "5. Deploy Harbor Registry"
log "Deploying Harbor..."
helm repo add harbor https://helm.goharbor.io 2>/dev/null
helm repo update > /dev/null

helm upgrade --install harbor harbor/harbor \
  --namespace $HARBOR_NAMESPACE \
  --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
  --set expose.type=nodePort \
  --set expose.tls.enabled=true \
  --set expose.tls.certSource=secret \
  --set expose.tls.secret.secretName=harbor-https-secret \
  --set expose.tls.nodePort=$HTTPS_NODE_PORT \
  --set expose.nodePort.httpNodePort=$HTTP_NODE_PORT \
  --set externalURL="https://$DATA_IP:$HTTPS_NODE_PORT" \
  --set persistence.persistentVolumeClaim.registry.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.registry.size=200Gi \
  --set persistence.persistentVolumeClaim.jobservice.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.database.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.redis.storageClass=$STORAGE_CLASS \
  --set persistence.persistentVolumeClaim.trivy.storageClass=$STORAGE_CLASS \
  --set internalTLS.enabled=false \
  --wait

step "6. Deploy Monitoring (Production Config)"
log "Generating Production Values for Prometheus & Grafana..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null
helm repo update > /dev/null

# Clean Production Values - No Comments
cat <<EOF > /tmp/monitoring-prod-values.yaml
grafana:
  service:
    type: NodePort
    nodePort: $GRAFANA_PORT
  persistence:
    enabled: true
    storageClass: $STORAGE_CLASS
    size: 20Gi
  grafana.ini:
    auth.anonymous:
      enabled: true
      org_role: Viewer
      org_name: GPU Cluster
    security:
      allow_embedding: true
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
prometheus:
  prometheusSpec:
    retention: 15d
    serviceMonitorSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: $STORAGE_CLASS
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: $STORAGE_CLASS
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
EOF

log "Deploying kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace $MONITOR_NAMESPACE \
  --create-namespace \
  -f /tmp/monitoring-prod-values.yaml \
  --wait

step "7. Deploy GPU Metrics (DCGM)"
if [ -f "$DCGM_MANIFEST_PATH" ]; then
    log "Deploying DCGM Exporter..."
    kubectl apply -f "$DCGM_MANIFEST_PATH"
    
    # Ensure ServiceMonitor exists
    cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter-manual
  namespace: $MONITOR_NAMESPACE
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: dcgm-exporter
  namespaceSelector:
    matchNames:
      - $MONITOR_NAMESPACE
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
EOF
else
    warn "DCGM manifest missing. Skipping."
fi

step "8. Import Dashboards"
install_dashboard() {
    local ID=$1
    local NAME=$2
    local FILE="/tmp/${NAME}.json"
    log "Fetching Dashboard ID: $ID ($NAME)..."
    curl -sL -o "$FILE" "https://grafana.com/api/dashboards/${ID}/revisions/latest/download"
    # Auto-fix datasource
    sed -i 's/"datasource": *"[^"]*"/"datasource": "Prometheus"/g' "$FILE"
    sed -i 's/${DS_PROMETHEUS}/Prometheus/g' "$FILE"
    
    kubectl create configmap "grafana-dashboard-${NAME}" \
      --namespace $MONITOR_NAMESPACE \
      --from-file="${NAME}.json=${FILE}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - grafana_dashboard=1 -o yaml | \
      kubectl apply -f -
    rm "$FILE"
}

# Standard GPU Dashboards
install_dashboard 12239 "nvidia-gpu"
install_dashboard 15758 "ns-view"
install_dashboard 15761 "ns-compute"
install_dashboard 6417  "cluster-top"

log "Reloading Grafana..."
kubectl rollout restart deployment kube-prometheus-stack-grafana -n $MONITOR_NAMESPACE

step "9. Expose Longhorn Dashboard (Public)"
log "Configuring Longhorn UI to be publicly accessible (NodePort)..."

# Patch the service to NodePort
# kubectl patch svc longhorn-frontend -n $LONGHORN_NAMESPACE --type='json' \
#   -p="[{'op': 'replace', 'path': '/spec/type', 'value': 'NodePort'}]"

# # Try to set specific port (may fail if port is taken, but we try)
# cat <<EOF | kubectl apply -f -
# apiVersion: v1
# kind: Service
# metadata:
#   name: longhorn-frontend
#   namespace: $LONGHORN_NAMESPACE
# spec:
#   type: NodePort
#   selector:
#     app: longhorn-ui
#   ports:
#   - name: http
#     port: 80
#     targetPort: http
#     nodePort: $LONGHORN_UI_PORT
# EOF

# log "Longhorn UI configured."

step "10. Deployment Summary"
echo "========================================================"
echo -e "${GREEN}   PRODUCTION DEPLOYMENT COMPLETE ${NC}"
echo "========================================================"
echo -e "Access these URLs via your Management IP ($UI_IP):"
echo -e "   1. Harbor UI:    https://$UI_IP:$HTTPS_NODE_PORT"
echo -e "   2. Grafana:      http://$UI_IP:$GRAFANA_PORT"
# echo -e "   3. Longhorn UI:  http://$UI_IP:$LONGHORN_UI_PORT"
echo ""
echo -e "Docker Pull Command (High Speed / Internal):"
echo -e "   docker pull $DATA_IP:$HTTPS_NODE_PORT/project/image:tag"
echo "========================================================"