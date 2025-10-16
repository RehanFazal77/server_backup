#!/bin/bash

echo "--- Step 1 of 2: Creating the BareMetalHost ---"
cat << EOF | kubectl apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: bmh-smo-hpe15
  namespace: default
spec:
  online: true
  bootMACAddress: "3c:fd:fe:ef:0e:f4"
  bootMode: UEFI
  externallyProvisioned: true
EOF

echo ""
echo "--- Step 2 of 2: Creating all Cluster API resources ---"
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
      hostSelector: {}
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
    - name: "rehanfazal"
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
  hostSelector: {}
EOF

echo ""
echo "--- All resources created. Starting to monitor the provisioning process... ---"
watch kubectl get cluster,machine,metal3machine,bmh -A
