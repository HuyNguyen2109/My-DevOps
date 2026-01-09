#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="valkey"
VALKEY_CONFIG="valkey-config"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Check if Vault CLI is installed ===
echo "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    echo "❌ Vault CLI is not installed!"
    exit 1
fi
echo "Checking Vault credentials for Vault..."
REQUIRED_VARS=(
  VAULT_ADDR
  VAULT_TOKEN
)
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# === Get secrets from Vault ===
echo "🔐 Fetching secrets from Vault..."
VALKEY_AUTH_PASSWORD=$(vault kv get -field=valkey-auth-password kubernetes/docker-secrets)
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $VALKEY_CONFIG >/dev/null 2>&1 || true
cat <<EOF | docker config create $VALKEY_CONFIG -
# valkey.conf - minimal config for production-like use

bind 0.0.0.0
protected-mode yes
requirepass $VALKEY_AUTH_PASSWORD

port 6379
daemonize no
supervised no

# Persistence
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# Optional: snapshotting (RDB)
save 900 1
save 300 10
save 60 10000

dir /data

# Memory limit
maxmemory 1500mb
maxmemory-policy allkeys-lru

# Logging
logfile ""
loglevel notice

EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach=true
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"

# Also trigger authentik instance re-deploy to apply new Valkey instance
echo "Triggering authentik instance re-deploy..."
cd ../authentik
./deploy_authentik.sh
cd ../valkey
