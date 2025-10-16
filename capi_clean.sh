#!/bin/bash

# A list of all the resource types we have created
RESOURCETYPES=(
  "cluster.cluster.x-k8s.io"
  "machine.cluster.x-k8s.io"
  "metal3machine.infrastructure.cluster.x-k8s.io"
  "kubeadmcontrolplane.controlplane.cluster.x-k8s.io"
  "metal3machinetemplate.infrastructure.cluster.x-k8s.io"
  "metal3cluster.infrastructure.cluster.x-k8s.io"
  "baremetalhost.metal3.io"
)

echo "--- Starting Force Deletion ---"

# Loop through each resource type
for RT in "${RESOURCETYPES[@]}"; do
  echo ""
  echo ">>> Processing resource type: $RT"
  # Get all resources of this type in the default namespace
  RESOURCES=$(kubectl get $RT -n default -o name)
  if [ -z "$RESOURCES" ]; then
    echo "No resources found to patch."
  else
    # Loop through each resource and remove its finalizers
    for RES in $RESOURCES; do
      echo "Forcibly removing finalizers from $RES..."
      kubectl patch $RES -n default -p '{"metadata":{"finalizers":[]}}' --type=merge
    done
  fi
done

echo ""
echo "--- Finalizers removed. Now issuing delete commands. ---"
# Now that finalizers are gone, a simple delete will work
kubectl delete cluster,machine,metal3machine,kubeadmcontrolplane,metal3machinetemplate,metal3cluster,baremetalhost --all -n default

echo ""
echo "--- Verification ---"
# Check that everything is gone
RESOURCES_LEFT=$(kubectl get cluster,machine,metal3machine,kubeadmcontrolplane,metal3machinetemplate,metal3cluster,baremetalhost -n default 2>&1)

if [[ $RESOURCES_LEFT == *"No resources found"* ]]; then
  echo "✅ SUCCESS: All cluster resources have been successfully deleted."
  echo "You are now at a clean slate."
else
  echo "⚠️ WARNING: Some resources may still be terminating. Please check with:"
  echo "kubectl get cluster,machine,metal3machine,kubeadmcontrolplane,metal3machinetemplate,metal3cluster,baremetalhost -A"
fi
