#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="portainer-prd"
MASTER_DATA_FOLDER="/mnt/docker/data"
REQUIRED_DIRECTORY="portainer"
SSH_KEY="$HOME/ssh-keys/oracle.key"
NODE_USER="root"
NODES=("docker-swarm-manager")

log "SSH to node to create required sub-directories"
for NODE in "${NODES[@]}"; do
  log "🔧 Preparing data folder on $NODE..."
  ssh -i $SSH_KEY $NODE_USER@$NODE "sudo mkdir -p $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY"
done

# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
export UI_URL="docker-ui.mcb-svc.work"
export IMAGE_TAG="2.35.0-alpine"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
