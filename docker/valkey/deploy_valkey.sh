#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="valkey"
VALKEY_CONFIG="valkey-config"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Check if Azure CLI is installed ===
echo "Checking az cli is installed..."
if ! command -v az >/dev/null 2>&1; then
    echo "❌ Azure CLI (az) is not installed. Please install it first: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi
echo "Checking Azure credentials for Azure Key Vault on host machine..."
REQUIRED_VARS=(
  AZURE_CLIENT_ID
  AZURE_CLIENT_SECRET
  AZURE_TENANT_ID
  AZURE_SUBSCRIPTION_ID
  AZURE_VAULT_NAME
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# === Get secrets from Azure Key Vault ===
echo "🔐 Fetching secrets from Azure Key Vault..."
VALKEY_AUTH_PASSWORD=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "valkey-auth-password" --query "value" -o tsv)
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
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
