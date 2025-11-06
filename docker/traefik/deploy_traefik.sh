#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="traefik"
TRAEFIK_CONFIG_FILE="traefik-config"
TRAEFIK_MIDDLEWARE_FILE="traefik-middlewares"
TRAEFIK_FUNNEL_FILE="traefik-funnel"
MASTER_DATA_FOLDER="/mnt/docker/data"
REQUIRED_DIRECTORY="traefik"
SSH_KEY="$HOME/ssh-keys/oracle.key"
NODE_USER="root"
NODES=("docker-swarm-manager")
REQUIRED_SUB_DIR=("acme" "logs")

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
export PUBLIC_IP=$(curl -s ifconfig.me)
export ROOT_DOMAIN="mcb-svc.work"
export TRAEFIK_URL="sg.mcb-svc.work"
export IMAGE_TAG="v3.5.0-rc1"
export MASTER_DATA_FOLDER=$MASTER_DATA_FOLDER
# === Create Docker Config via STDIN ===
log "Parsing all necessary variables into config..."
docker config rm $TRAEFIK_CONFIG_FILE > /dev/null 2>&1 || true
docker config rm $TRAEFIK_MIDDLEWARE_FILE > /dev/null 2>&1 || true
docker config rm $TRAEFIK_FUNNEL_FILE > /dev/null 2>&1 || true
cat <<EOF | docker config create $TRAEFIK_CONFIG_FILE - > /dev/null 2>&1 || true
global:
  checkNewVersion: true

log:
  level: ERROR

accessLog:
  filePath: "/logs/access.log"
  bufferingSize: 100

api:
  insecure: true
  dashboard: true

entryPoints:
  valkey-redis:
    address: :6379
  pgbouncer:
    address: :6432
  postgres:
    address: :5432
  metrics:
    address: :8082
  console:
    address: ":8088"
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: "websecure"
          scheme: "https"
          permanent: true
  websecure:
    address: ":443"

providers:
  swarm:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-internetwork
  file:
    directory: "/etc/traefik/dynamic/"
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "JohnasHuy21091996@gmail.com"
      storage: "acme/acme.json"
      caServer: "https://acme-v02.api.letsencrypt.org/directory"
      dnsChallenge:
        provider: cloudflare
      httpChallenge:
        entryPoint: web

metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
    headerLabels:
      label: traefik-prod-sg
EOF

cat <<EOF | docker config create $TRAEFIK_MIDDLEWARE_FILE - > /dev/null 2>&1 || true
http:
  middlewares:
    authentik:
      forwardAuth:
        address: http://authentik-outpost-proxy:9000/outpost.goauthentik.io/auth/traefik
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-entitlements
          - X-authentik-email
          - X-authentik-name
          - X-authentik-uid
          - X-authentik-jwt
          - X-authentik-meta-jwks
          - X-authentik-meta-outpost
          - X-authentik-meta-provider
          - X-authentik-meta-app
          - X-authentik-meta-version
EOF

cat <<EOF | docker config create $TRAEFIK_FUNNEL_FILE - > /dev/null 2>&1 || true
http:
  routers:
    proxmox:
      rule: "Host(\"proxmox.mcb-svc.work\")"
      entryPoints:
        - websecure
      service: proxmox-service
      tls:
        certResolver: letsencrypt
  services:
    proxmox-service:
      loadBalancer:
        servers:
          - url: "https://192.168.1.6:8006"
        serversTransport: insecureTransport
  serversTransports:
    insecureTransport:
      insecureSkipVerify: true
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach > /dev/null 2>&1 || true
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
