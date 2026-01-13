#!/bin/bash
set -e

HARBOR_NAMESPACE="harbor"
INSTALLER_NAMESPACE="harbor-certs"
DATA_IP="192.168.110.1"
UI_IP="192.168.109.1"
HTTPS_NODE_PORT=30003
STORAGE_HOSTNAME="gpu1-storage"
CERTS_DIR="certs"

mkdir -p "$CERTS_DIR"

if [ ! -f "$CERTS_DIR/ca.crt" ]; then
    openssl genrsa -out "$CERTS_DIR/ca.key" 4096
    openssl req -x509 -new -nodes -sha512 -days 3650 \
     -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=Harbor-CA" \
     -key "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt"
fi

openssl genrsa -out "$CERTS_DIR/harbor.key" 4096
openssl req -new -key "$CERTS_DIR/harbor.key" -out "$CERTS_DIR/harbor.csr" \
  -subj "/C=TW/ST=Taipei/L=Taipei/O=GPU-Cluster/OU=IT/CN=$DATA_IP"

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

openssl x509 -req -in "$CERTS_DIR/harbor.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
 -out "$CERTS_DIR/harbor.crt" -days 3650 -sha512 -extfile "$CERTS_DIR/v3.ext"

sudo mkdir -p "/etc/docker/certs.d/$DATA_IP:$HTTPS_NODE_PORT"
sudo cp "$CERTS_DIR/ca.crt" "/etc/docker/certs.d/$DATA_IP:$HTTPS_NODE_PORT/ca.crt"

kubectl create namespace $HARBOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $HARBOR_NAMESPACE delete secret harbor-https-secret --ignore-not-found
kubectl -n $HARBOR_NAMESPACE create secret tls harbor-https-secret \
  --key "$CERTS_DIR/harbor.key" \
  --cert "$CERTS_DIR/harbor.crt"

CA_HASH=$(sha256sum "$CERTS_DIR/ca.crt" | cut -d' ' -f1)

kubectl create namespace $INSTALLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap harbor-ca-cert \
  --namespace $INSTALLER_NAMESPACE \
  --from-file=ca.crt="$CERTS_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

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
      initContainers:
      - name: install-cert
        image: alpine:latest
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e
            HOSTS_DIR="/host/etc/containerd/certs.d/$DATA_IP:$HTTPS_NODE_PORT"
            mkdir -p "\$HOSTS_DIR"
            cp /config/ca.crt "\$HOSTS_DIR/ca.crt"
            printf 'server = "https://%s:%s"\n' "$DATA_IP" "$HTTPS_NODE_PORT" > "\$HOSTS_DIR/hosts.toml"
            printf '[host."https://%s:%s"]\n' "$DATA_IP" "$HTTPS_NODE_PORT" >> "\$HOSTS_DIR/hosts.toml"
            printf '  ca = "/etc/containerd/certs.d/%s:%s/ca.crt"\n' "$DATA_IP" "$HTTPS_NODE_PORT" >> "\$HOSTS_DIR/hosts.toml"
            if ! grep -q "config_path = \"/etc/containerd/certs.d\"" /host/etc/containerd/config.toml; then
               sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' /host/etc/containerd/config.toml
            fi
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

kubectl rollout status daemonset/harbor-cert-installer -n $INSTALLER_NAMESPACE --timeout=60s