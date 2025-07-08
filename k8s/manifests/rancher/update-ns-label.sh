#!/bin/bash

# Target label key and old/new values
LABEL_KEY="field.cattle.io/projectId"
OLD_VALUE="$1"
NEW_VALUE=""

# Get all namespaces with the specific label value
namespaces=$(kubectl get ns -l "${LABEL_KEY}=${OLD_VALUE}" -o jsonpath='{.items[*].metadata.name}')

if [[ -z "$namespaces" ]]; then
  echo "No namespaces found with label ${LABEL_KEY}=${OLD_VALUE}"
  exit 0
fi

echo "Updating namespaces with label ${LABEL_KEY}=${OLD_VALUE}..."

for ns in $namespaces; do
  echo "Patching namespace: $ns"

  # Remove old label
  kubectl label ns "$ns" "${LABEL_KEY}-" --overwrite

  # Add new label (empty value)
  kubectl label ns "$ns" "${LABEL_KEY}=${NEW_VALUE}" --overwrite
done

echo "Update complete."
