#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="hashicorp"
CONFIG_FILE="vault_config"
# === Check if Azure CLI is installed ===
echo "Checking az cli is installed..."
if ! command -v az >/dev/null 2>&1; then
    echo "❌ Azure CLI (az) is not installed. Please install it first: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi
echo "Checking Azure credentials for Azure Key Vault..."
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
PG_CONNECTION_STRING=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "connection-string" --query "value" -o tsv)
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $CONFIG_FILE
cat <<EOF | docker config create $CONFIG_FILE -
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
# === Load environment variables from .env file ===
echo "Loading variables into cmd"
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
