#!/bin/bash
set -eo pipefail

# Configuration
HARBOR_NAMESPACE="harbor"
INSTALLER_NAMESPACE="harbor-certs"
DATA_IP="192.168.110.1"
HTTPS_NODE_PORT=30003
CERTS_DIR="./certs"

mkdir -p "$CERTS_DIR"

# 1. Check for existing CA. If exists, do not generate a new one.
if [[ -f "$CERTS_DIR/ca.key" && -f "$CERTS_DIR/ca.crt" ]]; then
    echo "Existing CA found. Keeping current CA to ensure consistency."
else
    echo "No CA found. Generating new Root CA..."
    openssl genrsa -out "$CERTS_DIR/ca.key" 4096
    openssl req -x509 -new -nodes -sha512 -days 3650 \
      -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/CN=Harbor-CA" \
      -key "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt"
fi

# 2. Cleanup old server certificates to ensure only fresh ones are used
rm -f "$CERTS_DIR/harbor.key" "$CERTS_DIR/harbor.crt" "$CERTS_DIR/harbor.csr" "$CERTS_DIR/v3.ext"

# 3. Generate new Server Certificate
openssl genrsa -out "$CERTS_DIR/harbor.key" 4096
openssl req -new -key "$CERTS_DIR/harbor.key" -out "$CERTS_DIR/harbor.csr" \
  -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/CN=$DATA_IP"

cat > "$CERTS_DIR/v3.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = IP:$DATA_IP,IP:127.0.0.1
EOF

openssl x509 -req -in "$CERTS_DIR/harbor.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
  -CAcreateserial -out "$CERTS_DIR/harbor.crt" -days 3650 -sha512 -extfile "$CERTS_DIR/v3.ext"

# 4. Update Kubernetes Resources
kubectl create namespace $HARBOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Delete old secret to ensure update
kubectl -n $HARBOR_NAMESPACE delete secret harbor-https-secret --ignore-not-found
kubectl -n $HARBOR_NAMESPACE create secret tls harbor-https-secret \
  --key "$CERTS_DIR/harbor.key" --cert "$CERTS_DIR/harbor.crt"

kubectl create namespace $INSTALLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $INSTALLER_NAMESPACE create configmap harbor-ca-cert \
  --from-file=ca.crt="$CERTS_DIR/ca.crt" --dry-run=client -o yaml | kubectl apply -f -

# 5. Deploy Installer DaemonSet
# Using a simplified heredoc to prevent YAML parsing errors (line 48 issue)
CA_HASH=$(sha256sum "$CERTS_DIR/ca.crt" | cut -d' ' -f1)

cat <<EOF | kubectl apply -f -
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
      annotations:
        ca-content-hash: "$CA_HASH"
      labels:
        app: harbor-cert-installer
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: installer
        image: alpine:latest
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e
            TARGET_DIR="/host/etc/containerd/certs.d/$DATA_IP:$HTTPS_NODE_PORT"
            mkdir -p "\$TARGET_DIR"
            cp /config/ca.crt "\$TARGET_DIR/ca.crt"

            printf 'server = "https://%s:%s"\n[host."https://%s:%s"]\n  ca = "/etc/containerd/certs.d/%s:%s/ca.crt"\n' \
            "$DATA_IP" "$HTTPS_NODE_PORT" "$DATA_IP" "$HTTPS_NODE_PORT" "$DATA_IP" "$HTTPS_NODE_PORT" > "\$TARGET_DIR/hosts.toml"

            CONFIG="/host/etc/containerd/config.toml"
            if ! grep -q "config_path = \"/etc/containerd/certs.d\"" "\$CONFIG"; then
              cp "\$CONFIG" "\$CONFIG.bak"
              sed -i '/config_path =/d' "\$CONFIG"
              sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a \      config_path = "/etc/containerd/certs.d"' "\$CONFIG"
              nsenter --target 1 --mount -- systemctl restart containerd
            fi
            sleep infinity
        volumeMounts:
        - name: host-etc
          mountPath: /host/etc
        - name: cert-config
          mountPath: /config
      volumes:
      - name: host-etc
        hostPath:
          path: /etc
      - name: cert-config
        configMap:
          name: harbor-ca-cert
EOF

kubectl rollout status daemonset/harbor-cert-installer -n $INSTALLER_NAMESPACE --timeout=120s
echo "Certificate update completed successfully."