#!/bin/bash
set -e

# --- Configuration ---
HARBOR_NAMESPACE="harbor"
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-"HarborProd123!"}
# HTTPS Port (NodePort)
HTTPS_NODE_PORT=30003
# HTTP Port (Redirect to HTTPS)
HTTP_NODE_PORT=30002

# Color Definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }

echo "========================================================"
echo "   Harbor Deployment with Self-Signed HTTPS             "
echo "========================================================"

# 1. Get External IP
EXT_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
log "Detected External IP: $EXT_IP"

# 2. Generate Self-Signed Certificates
log "Generating Self-Signed Certificates..."
mkdir -p certs

# Generate CA
openssl genrsa -out certs/ca.key 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/C=TW/ST=Taiwan/L=Taipei/O=MyOrg/OU=IT/CN=$EXT_IP" \
 -key certs/ca.key \
 -out certs/ca.crt

# Generate Server Key
openssl genrsa -out certs/harbor.key 4096

# Generate CSR
openssl req -new -key certs/harbor.key -out certs/harbor.csr \
    -subj "/C=TW/ST=Taiwan/L=Taipei/O=MyOrg/OU=IT/CN=$EXT_IP"

# Generate Extension file for SAN (Subject Alternative Name) - CRITICAL for IP access
cat > certs/v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
IP.1 = $EXT_IP
EOF

# Sign the certificate
openssl x509 -req -in certs/harbor.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
 -out certs/harbor.crt -days 3650 -sha512 -extfile certs/v3.ext

log "Certificates generated in ./certs/"

# 3. Create Namespace & Secret
log "Configuring Kubernetes Secret..."
kubectl create namespace $HARBOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Delete old secret if exists
kubectl -n $HARBOR_NAMESPACE delete secret harbor-https-secret --ignore-not-found

# Create new TLS secret
kubectl -n $HARBOR_NAMESPACE create secret tls harbor-https-secret \
  --key certs/harbor.key \
  --cert certs/harbor.crt

# 4. Deploy Harbor with HTTPS
log "Deploying Harbor via Helm..."
helm repo add harbor https://helm.goharbor.io 2>/dev/null
helm repo update > /dev/null

if helm list -n $HARBOR_NAMESPACE | grep -q "harbor"; then
    log "Harbor is already installed. Skipping installation..."
else
    helm upgrade --install harbor harbor/harbor \
      --namespace $HARBOR_NAMESPACE \
      --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
      --set expose.type=nodePort \
      --set expose.tls.enabled=true \
      --set expose.tls.certSource=secret \
      --set expose.tls.secret.secretName=harbor-https-secret \
      --set expose.tls.nodePort=$HTTPS_NODE_PORT \
      --set expose.nodePort.httpNodePort=$HTTP_NODE_PORT \
      --set externalURL="https://$EXT_IP:$HTTPS_NODE_PORT" \
      --set persistence.persistentVolumeClaim.registry.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.registry.size=200Gi \
      --set persistence.persistentVolumeClaim.jobservice.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.database.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.redis.storageClass=nfs-client \
      --set persistence.persistentVolumeClaim.trivy.storageClass=nfs-client \
      --wait
fi

# --- 8. Deploy Monitoring ---
log "Step 6: Deploying Monitoring Stack..."

# Check if Monitoring is already installed
if helm list -n monitoring | grep -q "kube-prometheus-stack"; then
    log "Monitoring stack already installed. Skipping..."
else
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Using local variables if defined, otherwise defaults
    GRAFANA_PORT=${GRAFANA_PORT:-30004}
    STORAGE_CLASS="nfs-client"

    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --set grafana.service.type=NodePort \
      --set grafana.service.nodePort=$GRAFANA_PORT \
      --set grafana.persistence.enabled=true \
      --set grafana.persistence.storageClass=$STORAGE_CLASS \
      --set grafana.persistence.size=10Gi \
      --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=$STORAGE_CLASS \
      --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi
fi

# 5. Summary & Client Config
echo "========================================================"
log "Harbor Deployed Successfully with HTTPS!"
echo "========================================================"
echo -e "   URL:      https://$EXT_IP:$HTTPS_NODE_PORT"
echo -e "   User:     admin"
echo -e "   Password: $HARBOR_ADMIN_PASSWORD"
echo "--------------------------------------------------------"
warn "IMPORTANT: Since this is a Self-Signed Certificate, you MUST configure your Docker clients:"
echo ""
echo "Step 1: On every machine that needs to pull/push images (including K8s nodes):"
echo "   sudo mkdir -p /etc/docker/certs.d/$EXT_IP:$HTTPS_NODE_PORT"
echo "   sudo cp $(pwd)/certs/ca.crt /etc/docker/certs.d/$EXT_IP:$HTTPS_NODE_PORT/ca.crt"
echo ""
echo "Step 2: Restart Docker"
echo "   sudo systemctl restart docker"
echo "========================================================"