#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="hashicorp"
CONFIG_FILE="vault-config"
MASTER_DATA_FOLDER="/mnt/docker/data"
REQUIRED_DIRECTORY="vault"
SSH_KEY="$HOME/ssh-keys/oracle.key"
NODE_USER="root"
NODES=("docker-swarm-manager")
REQUIRED_SUB_DIR=("data" "logs")

log "SSH to node to create required sub-directories"
for NODE in "${NODES[@]}"; do
  log "🔧 Preparing data folder on $NODE..."
  for DIR in "${REQUIRED_SUB_DIR[@]}"; do
    ssh -i $SSH_KEY $NODE_USER@$NODE "sudo mkdir -p $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY/$DIR && sudo chown docker:docker $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY/$DIR"
  done
done
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Check if Azure CLI is installed ===
log "Checking az cli is installed..."
if ! command -v az >/dev/null 2>&1; then
    err "❌ Azure CLI (az) is not installed. Please install it first: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi
log "Checking Azure credentials for Azure Key Vault..."
REQUIRED_VARS=(
  AZURE_CLIENT_ID
  AZURE_CLIENT_SECRET
  AZURE_TENANT_ID
  AZURE_SUBSCRIPTION_ID
  AZURE_VAULT_NAME
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    err "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# === Get secrets from Azure Key Vault ===
log "🔐 Fetching secrets from Azure Key Vault..."
PG_CONNECTION_STRING=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "connection-string" --query "value" -o tsv)
export VAULT_URL="vault.mcb-svc.work"
export IMAGE_TAG="1.21.0"
export MASTER_DATA_FOLDER=$MASTER_DATA_FOLDER
# === Create Docker Config via STDIN ===
log "Parsing all necessary variables into config..."
docker config rm $CONFIG_FILE > /dev/null 2>&1 || true
cat <<EOF | docker config create $CONFIG_FILE - > /dev/null 2>&1 || true
ui = true
disable_mlock = true

storage "postgresql" {
  connection_url = "$PG_CONNECTION_STRING"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}

seal "azurekeyvault" {
  tenant_id      = "$AZURE_TENANT_ID"
  client_id      = "$AZURE_CLIENT_ID"
  client_secret  = "$AZURE_CLIENT_SECRET"
  vault_name     = "$AZURE_VAULT_NAME"
  key_name       = "unseal-key-hcl"
}
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
