#!/bin/bash

# A list of all the resource types we have created that might be stuck
RESOURCETYPES=(
  "cluster.cluster.x-k8s.io"
  "machine.cluster.x-k8s.io"
  "metal3machine.infrastructure.cluster.x-k8s.io"
  "kubeadmcontrolplane.controlplane.cluster.x-k8s.io"
  "metal3machinetemplate.infrastructure.cluster.x-k8s.io"
  "metal3cluster.infrastructure.cluster.x-k8s.io"
  "baremetalhost.metal3.io"
)

echo "--- Starting Force Deletion of All Cluster API Resources ---"

# Loop through each resource type to remove finalizers
for RT in "${RESOURCETYPES[@]}"; do
  RESOURCES=$(kubectl get $RT -n default -o name)
  if [ -n "$RESOURCES" ]; then
    echo ">>> Forcibly removing finalizers from resources of type: $RT"
    for RES in $RESOURCES; do
      kubectl patch $RES -n default -p '{"metadata":{"finalizers":[]}}' --type=merge
    done
  fi
done

echo ""
echo "--- Finalizers removed. Now issuing delete commands to clean up. ---"
kubectl delete cluster,machine,metal3machine,kubeadmcontrolplane,metal3machinetemplate,metal3cluster,baremetalhost --all -n default

echo ""
echo "--- Verification ---"
# Check that everything is gone
RESOURCES_LEFT=$(kubectl get cluster,machine,metal3machine,kubeadmcontrolplane,metal3machinetemplate,metal3cluster,baremetalhost -n default 2>&1)
if [[ $RESOURCES_LEFT == *"No resources found"* ]]; then
  echo "✅ SUCCESS: All cluster resources have been successfully deleted. You are at a clean slate."
else
  echo "⚠️ WARNING: Some resources may still be terminating. Please re-run the cleanup script."
fi
