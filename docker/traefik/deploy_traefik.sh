#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="traefik"
TRAEFIK_CONFIG_FILE="traefik-config"
TRAEFIK_MIDDLEWARE_FILE="traefik-middlewares"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $TRAEFIK_CONFIG_FILE
docker config rm $TRAEFIK_MIDDLEWARE_FILE
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
    filename: "/etc/traefik/middlewares.yaml"

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
      # basicAuth:
      #   users:
      #     - "$TRAEFIK_USER:$TRAEFIK_PASSWORD"
      forwardAuth:
        address: http://server:9000/outpost.goauthentik.io/auth/traefik
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
# Load environment variables from .env file
if [ -f .env ]; then
    set -a  # Automatically export all variables
    source .env
    set +a
else
    echo "⚠️  .env file not found! Make sure it exists in the current directory."
    exit 1
fi
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
