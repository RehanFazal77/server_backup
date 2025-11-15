#!/bin/bash

# Kubernetes v1.29.0 Installation Script with Calico CNI
# Pod CIDR: 192.168.0.0/16
# Includes Docker and Local-Path Storage Provisioner

set -e

echo "=========================================="
echo "Kubernetes v1.29.0 Installation Script"
echo "CNI: Calico" #update the CNI part to use different CNI(falnnel)
echo "Pod CIDR: 192.168.0.0/16"
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Retry function for network operations
retry() {
    local retries=3
    local count=0
    until "$@"; do
        exit=$?
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            echo "Command failed. Attempt $count/$retries. Retrying..."
            sleep 5
        else
            echo "Command failed after $retries attempts."
            return $exit
        fi
    done
    return 0
}

# Function to install package if missing
install_if_missing() {
    for pkg in "$@"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            echo "Installing $pkg..."
            apt-get install -y "$pkg"
        fi
    done
}

# Disable swap
echo "[1/12] Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load kernel modules
echo "[2/12] Loading kernel modules..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configure sysctl parameters
echo "[3/12] Configuring sysctl parameters..."
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
# Install containerd
echo "[4/12] Installing containerd..."
apt-get update
apt-get install -y containerd

# Configure containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# Install kubeadm, kubelet, and kubectl
echo "[5/12] Installing Kubernetes packages..."
apt-get update
install_if_missing apt-transport-https ca-certificates curl gpg

mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet
# Initialize Kubernetes cluster
echo "[6/12] Initializing Kubernetes cluster..."
kubeadm init --pod-network-cidr=192.168.0.0/16 --kubernetes-version=v1.29.0

# Setup kubeconfig for root user
echo "[7/12] Setting up kubeconfig..."
export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Install Calico CNI
echo "[8/12] Installing Calico CNI..."
retry kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
# Create custom resources for Calico
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

echo "[9/12] Waiting for Calico to be ready..."
sleep 30

# Untaint master node (allow scheduling pods on master)
echo "[10/12] Removing taint from master node..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
# Install local-path storage provisioner
echo "[11/12] Installing local-path storage provisioner..."
STORAGE_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml"
retry kubectl apply -f $STORAGE_URL

echo "Waiting for local-path-provisioner deployment to be ready..."
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=300s

echo "Patching local-path storageclass as default..."
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Install Docker
echo "[12/12] Installing Docker..."
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Installing latest Docker..."
    export DEBIAN_FRONTEND=noninteractive
    retry apt-get update
    apt-get remove -y docker docker-engine docker.io runc || true

    install_if_missing ca-certificates curl gnupg lsb-release

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    retry apt-get update
    retry apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin
 # Add current user to docker group
    if [ -n "$SUDO_USER" ]; then
        usermod -aG docker $SUDO_USER || true
        echo "✅ Added $SUDO_USER to docker group. Log out and log back in to apply group changes."
    fi

    echo "✅ Docker installed successfully: $(docker --version)"
else
    echo "✅ Docker is already installed: $(docker --version)"
fi

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Cluster Information:"
kubectl cluster-info
echo ""
echo "Node Status:"
kubectl get nodes -o wide
echo ""
echo "Pod Status:"
kubectl get pods -A
echo ""
echo "Storage Class:"
kubectl get storageclass
echo ""
echo "Docker Version:"
docker --version
echo ""
echo "=========================================="
echo "Post-Installation Notes:"
echo "=========================================="
echo ""
echo "1. To use kubectl as a non-root user, run:"
echo "   mkdir -p \$HOME/.kube"
echo "   sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
echo "   sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
echo ""
echo "2. To use Docker without sudo, log out and log back in"
echo ""
echo "3. To join worker nodes to this cluster, run:"
echo "   kubeadm token create --print-join-command"
echo ""
echo "4. Default storage class 'local-path' is configured"
echo ""

