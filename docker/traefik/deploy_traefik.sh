#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="traefik"
TRAEFIK_CONFIG_FILE="traefik-config"
TRAEFIK_MIDDLEWARE_FILE="traefik-middlewares"
TRAEFIK_FUNNEL_FILE="traefik-funnel"
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
# === Get secrets from Vault ===
echo "🔐 Fetching secrets from Vault..."
export CF_API_EMAIL="JohnasHuy21091996@gmail.com"
export CF_API_KEY=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "cloudflare-api-key" --query "value" -o tsv)
export PUBLIC_IP=$(curl -s ifconfig.me)
export ROOT_DOMAIN="mcb-svc.work"
export TRAEFIK_URL="sg.mcb-svc.work"
export IMAGE_TAG="v3.5.0-rc1"
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $TRAEFIK_CONFIG_FILE > /dev/null 2>&1 || true
docker config rm $TRAEFIK_MIDDLEWARE_FILE > /dev/null 2>&1 || true
cat <<EOF | docker config create $TRAEFIK_CONFIG_FILE -
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

cat <<EOF | docker config create $TRAEFIK_MIDDLEWARE_FILE -
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

cat <<EOF | docker config create $TRAEFIK_FUNNEL_FILE -
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
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
