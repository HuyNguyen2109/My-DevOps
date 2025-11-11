#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
STACK_NAME="termix-ssh"
MASTER_DATA_FOLDER="/mnt/docker/data"
REQUIRED_DIRECTORY="termix"
SSH_KEY="$HOME/ssh-keys/oracle.key"
NODE_USER="root"
NODES=("docker-swarm-manager")

export MASTER_DATA_FOLDER=$MASTER_DATA_FOLDER

log "SSH to node to create required sub-directories"
for NODE in "${NODES[@]}"; do
  log "🔧 Preparing data folder on $NODE..."
  ssh -i $SSH_KEY $NODE_USER@$NODE "sudo mkdir -p $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY && sudo chown docker:docker $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY"
done

# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true

# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"