#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="traefik"
MASTER_DATA_FOLDER="/mnt/docker/data"
REQUIRED_DIRECTORY="traefik"
SSH_KEY="$HOME/ssh-keys/oracle.key"
NODE_USER="root"
NODES=($SWARM_MANAGER_HOSTNAME)
REQUIRED_SUB_DIR=("acme" "logs" "dynamic")

log "SSH to node to create required sub-directories"
for NODE in "${NODES[@]}"; do
  log "🔧 Preparing data folder on $NODE..."
  for DIR in "${REQUIRED_SUB_DIR[@]}"; do
    if ssh -i $SSH_KEY $NODE_USER@$NODE "[ -d $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY/$DIR ]"; then
      log "  ✓ Directory $DIR already exists, skipping..."
    else
      log "  📁 Creating directory $DIR..."
      ssh -i $SSH_KEY $NODE_USER@$NODE "sudo mkdir -p $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY/$DIR && sudo chown docker:docker $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY/$DIR"
    fi
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
log "Checking Azure credentials for Azure Key Vault on host machine..."
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
# === Get secrets from Vault ===
log "🔐 Fetching secrets from Vault..."
export CF_API_EMAIL="JohnasHuy21091996@gmail.com"
export CF_API_KEY=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "cloudflare-api-key" --query "value" -o tsv)
export IMAGE_TAG="v3.6.5"
export MASTER_DATA_FOLDER=$MASTER_DATA_FOLDER
export SWARM_NODE_CODENAME="alpha"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
