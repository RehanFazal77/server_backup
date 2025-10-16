#!/bin/bash

# ==============================================================================
# PART 1: THE FINAL, FORCEFUL CLEANUP
# ==============================================================================
echo "--- PART 1: Starting Force Deletion of All Cluster API Resources ---"

RESOURCETYPES=(
  "cluster.cluster.x-k8s.io" "machine.cluster.x-k8s.io" 
  "metal3machine.infrastructure.cluster.x-k8s.io" 
  "kubeadmcontrolplane.controlplane.cluster.x-k8s.io" 
  "metal3machinetemplate.infrastructure.cluster.x-k8s.io" 
  "metal3cluster.infrastructure.cluster.x-k8s.io" "baremetalhost.metal3.io"
)

for RT in "${RESOURCETYPES[@]}"; do
  RESOURCES=$(kubectl get $RT -n default -o name 2>/dev/null)
  if [ -n "$RESOURCES" ]; then
    echo ">>> Forcibly removing finalizers from resources of type: $RT"
    kubectl patch $RESOURCES -n default -p '{"metadata":{"finalizers":[]}}' --type=merge
  fi
done

echo "--- Finalizers removed. Deleting all resources now. ---"
kubectl delete cluster,machine,metal3machine,kubeadmcontrolplane,metal3machinetemplate,metal3cluster,baremetalhost --all --now -n default

echo "✅ Cleanup complete. System is now at a clean slate."
echo ""


# ==============================================================================
# PART 2: CREATE AND INSTALL THE SSH KEY
# ==============================================================================
echo "--- PART 2: Setting up the required SSH key for provisioning ---"

# Prompt for user input
read -p "Please enter the username for the existing Ubuntu OS on hpe15: " HPE15_USER
read -p "Please enter the IP address of hpe15: " HPE15_IP

# Define the SSH key file path
SSH_KEY_FILE="$HOME/.ssh/smo_cluster_key"

# Create a new SSH keypair without a passphrase
echo ">>> Generating new SSH key at $SSH_KEY_FILE..."
ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_FILE" -N ""

# Copy the public key to the target server
echo ">>> Copying the public key to $HPE15_USER@$HPE15_IP. You may be asked for a password."
ssh-copy-id -i "${SSH_KEY_FILE}.pub" "$HPE15_USER@$HPE15_IP"

# Create the Kubernetes secret for the controllers to use
echo ">>> Creating the Kubernetes secret 'smo-cluster-ssh-key'..."
kubectl create secret generic smo-cluster-ssh-key \
  --from-file=ssh-privatekey="$SSH_KEY_FILE" \
  --from-file=ssh-publickey="${SSH_KEY_FILE}.pub" \
  --namespace=default

echo "✅ SSH key setup is complete."
echo ""


# ==============================================================================
# PART 3: DEPLOY THE CLUSTER AND MONITOR
# ==============================================================================
echo "--- PART 3: Deploying the final, corrected cluster configuration ---"

echo ">>> Creating the BareMetalHost with the correct label..."
cat << EOF | kubectl apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: bmh-smo-hpe15
  namespace: default
  labels:
    cluster.x-k8s.io/cluster-name: "smo-cluster1"
spec:
  online: true
  bootMACAddress: "3c:fd:fe:ef:0e:f4"
  bootMode: UEFI
  externallyProvisioned: true
EOF

echo ">>> Creating all Cluster API resources..."
cat << EOF | kubectl apply -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: smo-cluster1
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["192.168.0.0/16"]
    services:
      cidrBlocks: ["10.96.0.0/16"]
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: smo-cluster1-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: Metal3Cluster
    name: smo-cluster1
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: Metal3Cluster
metadata:
  name: smo-cluster1
  namespace: default
spec:
  controlPlaneEndpoint:
    host: "172.168.14.41"
    port: 6443
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: Metal3MachineTemplate
metadata:
  name: smo-cluster1-control-plane-template
  namespace: default
spec:
  template:
    spec:
      image:
        url: "http://dummy.image/dummy.img"
        checksum: "http://dummy.image/dummy.img.md5"
        checksumType: "md5"
        format: "raw"
      hostSelector:
        matchLabels:
          cluster.x-k8s.io/cluster-name: "smo-cluster1"
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: smo-cluster1-control-plane
  namespace: default
spec:
  replicas: 1
  version: "v1.29.0"
  machineTemplate:
    infrastructureRef:
      kind: Metal3MachineTemplate
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      name: smo-cluster1-control-plane-template
  kubeadmConfigSpec:
    joinConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          provider-id: metal3://{{ ds.meta_data.uuid }}
    initConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          provider-id: metal3://{{ ds.meta_data.uuid }}
    users:
    - name: "$HPE15_USER"
      sshAuthorizedKeys:
      - "dummy"
      sudo: "ALL=(ALL) NOPASSWD:ALL"
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: Machine
metadata:
  name: smo-cluster1-control-plane-0
  namespace: default
  annotations:
    metal3.io/BareMetalHost: "default/bmh-smo-hpe15"
    metal3.io/DeploymentSecretName: "smo-cluster-ssh-key"
spec:
  clusterName: smo-cluster1
  version: "v1.29.0"
  bootstrap:
    configRef:
      name: smo-cluster1-control-plane
      apiVersion: controlplane.cluster.x-k8s.io/v1beta1
      kind: KubeadmControlPlane
  infrastructureRef:
    name: smo-cluster1-control-plane-0
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: Metal3Machine
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: Metal3Machine
metadata:
  name: smo-cluster1-control-plane-0
  namespace: default
spec:
  image:
    url: "http://dummy.image/dummy.img"
    checksum: "http://dummy.image/dummy.img.md5"
    checksumType: "md5"
    format: "raw"
  hostSelector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: "smo-cluster1"
EOF

echo ""
echo "--- ✅ All resources created. Starting to monitor the provisioning process... ---"
watch kubectl get cluster,machine,metal3machine,bmh -A
