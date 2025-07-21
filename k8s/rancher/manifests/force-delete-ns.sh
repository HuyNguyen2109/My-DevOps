#!/bin/bash

STUCK_NS="$1"

if [[ -z "$STUCK_NS" ]]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

echo "Checking if namespace '$STUCK_NS' is stuck in terminating state..."
STATUS=$(kubectl get ns "$STUCK_NS" -o jsonpath='{.status.phase}' 2>/dev/null)

if [[ "$STATUS" != "Terminating" ]]; then
  echo "Namespace '$STUCK_NS' is not terminating. Nothing to do."
  exit 0
fi

echo "Starting kubectl proxy..."
kubectl proxy --port=8080 &

PROXY_PID=$!
sleep 2  # Wait for proxy to start

echo "Patching finalizers for namespace '$STUCK_NS'..."
curl -s -o /dev/null -w "%{http_code}\n" -X PUT \
  -H "Content-Type: application/json" \
  --data "{\"metadata\":{\"finalizers\":[]}}" \
  http://127.0.0.1:8080/api/v1/namespaces/${STUCK_NS}/finalize

echo "Cleaning up..."
kill $PROXY_PID

echo "Done. Check with: kubectl get ns ${STUCK_NS}"
