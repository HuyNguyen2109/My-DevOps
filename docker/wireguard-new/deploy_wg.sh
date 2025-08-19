#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="wireguard-new"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Env ===
export WG_HOST="wg.mcb-svc.work"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
