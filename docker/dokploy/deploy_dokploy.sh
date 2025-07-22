#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="dokploy"
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
REDIS_SECRET=$(vault kv get -field=valkey-auth-password kubernetes/docker-secrets)
POSTGRES_USER=$(vault kv get -field=azure-postgresql-user kubernetes/docker-secrets)
POSTGRES_PASSWORD=$(vault kv get -field=azure-postgresql-password kubernetes/docker-secrets)
POSTGRES_HOST=$(vault kv get -field=azure-postgresql-host kubernetes/docker-secrets)
export DATABASE_URL="postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/dokploy_db?sslmode=verify-full"
export BASE_URL="dokploy.mcb-svc.work"
export REDIS_URL="redis://:$REDIS_SECRET@valkey-server:6379"
export BETTER_AUTH_SECRET=$(vault kv get -field=authentik-secret-key kubernetes/docker-secrets)
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
