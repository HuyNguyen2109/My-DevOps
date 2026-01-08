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
REQUIRED_SUB_DIR=("acme" "logs" "dynamic")

# === Parse command-line arguments ===
SWARM_NODE_CODENAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node|--codename|-n)
      SWARM_NODE_CODENAME="$2"
      shift 2
      ;;
    -h|--help)
      log "Usage: $0 --node <SWARM_NODE_CODENAME>"
      log "Options:"
      log "  --node, --codename, -n    Specify the node codename (alpha, beta, gamma)"
      log "  -h, --help                Show this help message"
      log ""
      log "Example: $0 --node alpha"
      exit 0
      ;;
    *)
      err "❌ Unknown option: $1"
      err "Use --help for usage information"
      exit 1
      ;;
  esac
done

if [ -z "$SWARM_NODE_CODENAME" ]; then
  err "❌ SWARM_NODE_CODENAME is required."
  err "Usage: $0 --node <SWARM_NODE_CODENAME>"
  err "Example: $0 --node alpha"
  exit 1
fi

log "🎯 Deploying to node codename: $SWARM_NODE_CODENAME"

# === Set node-specific configuration based on codename ===
case "$SWARM_NODE_CODENAME" in
  alpha)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="root"
    NODES=($SWARM_MANAGER_HOSTNAME)
    ;;
  beta)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="root"
    NODES=($SWARM_WORKER_VN_HOSTNAME)
    ;;
  gamma)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="ubuntu"
    NODES=($SWARM_WORKER_SG_HOSTNAME)
    ;;
  *)
    err "❌ Unknown SWARM_NODE_CODENAME: $SWARM_NODE_CODENAME"
    err "Valid options: alpha, beta, gamma"
    exit 1
    ;;
esac

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
export SWARM_NODE_CODENAME
# Set your homelab LAN CIDR (adjust as needed)
export HOMELAB_LAN_CIDR="${HOMELAB_LAN_CIDR:-192.168.1.0/24}"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
