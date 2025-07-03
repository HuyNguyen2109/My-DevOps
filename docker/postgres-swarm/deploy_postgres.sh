#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="postgres-cluster"
POSTGRES_EXTENDED_CONF="postgres-extended-conf"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# Load environment variables from .env file
if [ -f .env ]; then
    set -a  # Automatically export all variables
    source .env
    set +a
else
    echo "⚠️  .env file not found! Make sure it exists in the current directory."
    exit 1
fi
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $POSTGRES_EXTENDED_CONF >/dev/null 2>&1 || true
cat <<EOF | docker config create $POSTGRES_EXTENDED_CONF -
    log_connections = yes
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
