#!/bin/bash
set -e
set -o pipefail

# Color Definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
err() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

echo "========================================================"
echo "   NVIDIA GPU Driver & Container Toolkit Auto-Installer "
echo "   Target: Production Kubernetes Nodes (Ubuntu/Debian)  "
echo "========================================================"

# --- 1. System & Hardware Check ---
log "Step 1: Checking Hardware & OS..."

# Check OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        err "This script is optimized for Ubuntu/Debian. Detected: $ID. Aborting to prevent damage."
    fi
else
    err "Cannot detect OS distribution."
fi

# Check for NVIDIA Hardware
log "Scanning PCI bus for NVIDIA devices..."
if ! lspci | grep -i "nvidia" > /dev/null; then
    err "No NVIDIA GPU device detected on PCI bus. Aborting."
else
    GPU_MODEL=$(lspci | grep -i "nvidia" | head -n 1 | cut -d ':' -f 3)
    log "Detected GPU: $GPU_MODEL"
fi

# --- 2. Clean Environment ---
log "Step 2: Cleaning up old/conflicting drivers..."

# Stop display manager if exists (to allow driver switch)
systemctl stop gdm 2>/dev/null || systemctl stop lightdm 2>/dev/null || true

# Purge old nvidia packages to ensure clean slate
# NOTE: Using DEBIAN_FRONTEND=noninteractive to avoid prompts
sudo DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y '^nvidia-.*' > /dev/null 2>&1 || true
sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y > /dev/null 2>&1 || true

# Disable Nouveau (Open Source Driver) explicitly
if ! grep -q "blacklist nouveau" /etc/modprobe.d/blacklist-nvidia-nouveau.conf 2>/dev/null; then
    log "Blacklisting 'nouveau' driver..."
    sudo bash -c "echo 'blacklist nouveau' > /etc/modprobe.d/blacklist-nvidia-nouveau.conf"
    sudo bash -c "echo 'options nouveau modeset=0' >> /etc/modprobe.d/blacklist-nvidia-nouveau.conf"
    sudo update-initramfs -u > /dev/null
fi

# --- 3. Install Driver ---
log "Step 3: Detecting and Installing Recommended Driver..."

sudo apt-get update -qq
sudo apt-get install -y ubuntu-drivers-common pciutils > /dev/null

# Detect recommended driver
RECOMMENDED_DRIVER=$(ubuntu-drivers devices | grep "recommended" | awk '{print $3}')

if [ -z "$RECOMMENDED_DRIVER" ]; then
    warn "No specific 'recommended' tag found. Falling back to auto-install logic."
else
    log "Target Driver Version: $RECOMMENDED_DRIVER"
fi

# Install
log "Installing driver (this may take a few minutes)..."
sudo ubuntu-drivers autoinstall

# --- 4. Install NVIDIA Container Toolkit (Vital for K8s) ---
log "Step 4: Installing NVIDIA Container Toolkit (for Kubernetes/Docker)..."

# Add Repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg --yes
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

sudo apt-get update -qq > /dev/null
sudo apt-get install -y nvidia-container-toolkit > /dev/null

# Configure Container Runtime (Docker/Containerd)
log "Configuring container runtime..."
sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
sudo nvidia-ctk runtime configure --runtime=containerd 2>/dev/null || true

# --- 5. Summary ---
echo "========================================================"
log "Installation Complete!"
echo "========================================================"
echo "Pending Action: SYSTEM REBOOT REQUIRED"
echo "--------------------------------------------------------"
echo "After reboot, verify installation with:"
echo "  1. Driver Status:   nvidia-smi"
echo "  2. K8s Recognition: kubectl get nodes -o json | jq '.items[].status.capacity'"
echo "--------------------------------------------------------"

read -p "Do you want to reboot now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo reboot
fi